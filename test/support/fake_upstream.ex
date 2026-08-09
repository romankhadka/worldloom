defmodule Worldloom.TestSupport.FakeUpstream do
  @moduledoc """
  A deterministic, instrumented HTTPS/WSS upstream used by whole-app tests.

  The server binds to loopback, keeps only aggregate counters, and is compiled
  exclusively in the test environment through `test/support`.
  """

  @behaviour WebSock

  import Plug.Conn

  @certificate Path.expand("test/support/fixtures/tls/localhost_certificate.pem")
  @private_key Path.expand("test/support/fixtures/tls/localhost_key.pem")
  @ca_file Path.expand("test/support/fixtures/tls/localhost_ca.pem")
  @fixture_directory Path.expand("test/support/fixtures/feeds")
  @drand_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
  @websocket_idle_timeout_ms 3_600_000
  @sources [:wikimedia, :usgs, :open_meteo, :bluesky, :ripe_ris, :drand, :solana]
  @counter_keys [
    :connection_opens,
    :active_connections,
    :peak_connections,
    :subscriptions,
    :requests,
    :emitted_windows
  ]

  @type source :: :wikimedia | :usgs | :open_meteo | :bluesky | :ripe_ris | :drand | :solana

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    options = validate_options!(options)
    stats_name = {:global, {__MODULE__, make_ref()}}
    fixtures = load_fixtures!()

    children = [
      %{
        id: :stats,
        start:
          {Agent, :start_link,
           [
             fn ->
               %{
                 counters: initial_counters(),
                 solana_enabled?: options.solana
               }
             end,
             [name: stats_name]
           ]}
      },
      %{
        id: :bandit,
        start:
          {Bandit, :start_link,
           [
             [
               plug:
                 {__MODULE__,
                  %{
                    protocol: :plug,
                    stats: stats_name,
                    fixtures: fixtures,
                    clock: options.clock,
                    cadence_ms: options.cadence_ms,
                    solana_enabled?: options.solana
                  }},
               scheme: :https,
               ip: {127, 0, 0, 1},
               port: options.port,
               certfile: @certificate,
               keyfile: @private_key,
               startup_log: false,
               http_2_options: [enabled: false],
               thousand_island_options: [
                 num_acceptors: 2,
                 silent_terminate_on_error: true
               ],
               websocket_options: [compress: false, max_frame_size: 300_000]
             ]
           ]}
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_all)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: {__MODULE__, System.unique_integer([:positive])},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      type: :supervisor
    }
  end

  @spec urls(pid()) :: %{
          wikimedia: String.t(),
          usgs: String.t(),
          open_meteo: String.t(),
          bluesky: String.t(),
          ripe_ris: String.t(),
          drand_origin: String.t(),
          solana: String.t() | nil,
          stats: String.t()
        }
  def urls(server) when is_pid(server) do
    base = "https://localhost:#{listener_port(server)}"
    websocket_base = "wss://localhost:#{listener_port(server)}"
    solana_enabled? = server |> child_pid(:stats) |> Agent.get(& &1.solana_enabled?)

    %{
      wikimedia: base <> "/wikimedia/v2/stream/recentchange",
      usgs: base <> "/usgs/earthquakes/feed/v1.0/summary/all_hour.geojson",
      open_meteo: base <> "/open-meteo/v1/forecast",
      bluesky: websocket_base <> "/bluesky/subscribe",
      ripe_ris: websocket_base <> "/ripe/stream",
      drand_origin: base,
      solana: if(solana_enabled?, do: websocket_base <> "/solana", else: nil),
      stats: base <> "/stats"
    }
  end

  @doc "Returns the local certificate authority used by every fake TLS endpoint."
  @spec ca_file() :: String.t()
  def ca_file, do: @ca_file

  @doc "Returns the fake drand Quicknet v2 chain-info endpoint."
  @spec drand_chain_info_url(pid()) :: String.t()
  def drand_chain_info_url(server) do
    urls(server).drand_origin <> "/v2/chains/#{@drand_chain_hash}/info"
  end

  @doc "Returns the fake drand Quicknet v2 endpoint for an exact positive round."
  @spec drand_round_url(pid(), pos_integer()) :: String.t()
  def drand_round_url(server, round) when is_integer(round) and round > 0 do
    urls(server).drand_origin <> "/v2/chains/#{@drand_chain_hash}/rounds/#{round}"
  end

  @impl WebSock
  def init(%{protocol: :plug} = options), do: options

  def init(%{protocol: :websocket} = state) do
    open_connection(state.stats, state.source)

    state =
      if state.source == :bluesky and state.subscription? do
        bump(state.stats, :bluesky, :subscriptions)
        schedule_window(state)
      else
        state
      end

    {:ok, state}
  end

  def call(%Plug.Conn{method: "GET", path_info: ["stats"]} = connection, options) do
    counters = Agent.get(options.stats, & &1.counters)
    json_response(connection, 200, counters)
  end

  def call(
        %Plug.Conn{
          method: "GET",
          path_info: ["wikimedia", "v2", "stream", "recentchange"]
        } = connection,
        options
      ) do
    serve_wikimedia(connection, options)
  end

  def call(
        %Plug.Conn{
          method: "GET",
          path_info: ["usgs", "earthquakes", "feed", "v1.0", "summary", "all_hour.geojson"]
        } = connection,
        options
      ) do
    serve_fixture(connection, options, :usgs)
  end

  def call(
        %Plug.Conn{method: "GET", path_info: ["open-meteo", "v1", "forecast"]} = connection,
        options
      ) do
    serve_fixture(connection, options, :open_meteo)
  end

  def call(
        %Plug.Conn{
          method: "GET",
          path_info: ["v2", "chains", @drand_chain_hash, "info"]
        } = connection,
        options
      ) do
    serve_request_fixture(connection, options, :drand_chain_info, :drand)
  end

  def call(
        %Plug.Conn{
          method: "GET",
          path_info: ["v2", "chains", @drand_chain_hash, "rounds", encoded_round]
        } = connection,
        options
      ) do
    serve_drand_round(connection, encoded_round, options)
  end

  def call(
        %Plug.Conn{method: "GET", path_info: ["bluesky", "subscribe"]} = connection,
        options
      ) do
    subscription? = valid_bluesky_subscription?(connection.query_string)
    upgrade_socket(connection, options, :bluesky, subscription?)
  end

  def call(
        %Plug.Conn{method: "GET", path_info: ["ripe", "stream"]} = connection,
        options
      ) do
    upgrade_socket(connection, options, :ripe_ris, false)
  end

  def call(
        %Plug.Conn{method: "GET", path_info: ["solana"]} = connection,
        %{solana_enabled?: true} = options
      ) do
    upgrade_socket(connection, options, :solana, false)
  end

  def call(connection, _options), do: send_resp(connection, 404, "not found")

  @impl WebSock
  def handle_in({encoded, [opcode: :text]}, %{source: :ripe_ris} = state) do
    case Jason.decode(encoded) do
      {:ok, %{"type" => "request_rrc_list", "data" => nil} = request}
      when map_size(request) == 2 ->
        response = %{
          "type" => "ris_rrc_list",
          "data" => ["rrc00.ripe.net", "rrc01.ripe.net"]
        }

        {:push, {:text, Jason.encode!(response)}, state}

      {:ok, subscription} ->
        acknowledge_ripe_subscription(subscription, state)

      _invalid ->
        {:ok, state}
    end
  end

  def handle_in({encoded, [opcode: :text]}, %{source: :solana} = state) do
    case Jason.decode(encoded) do
      {:ok, %{"jsonrpc" => "2.0", "id" => 1, "method" => "slotSubscribe"} = request}
      when map_size(request) == 3 ->
        bump(state.stats, :solana, :subscriptions)
        acknowledgement = %{"jsonrpc" => "2.0", "id" => 1, "result" => 7}

        {:push, {:text, Jason.encode!(acknowledgement)}, schedule_window(state)}

      _invalid ->
        {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_control(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info(:emit_window, state) do
    frames = deterministic_window(state)
    bump(state.stats, state.source, :emitted_windows)

    next_state =
      state
      |> Map.update!(:window_index, &(&1 + 1))
      |> Map.put(:window_scheduled?, false)
      |> schedule_window()

    encoded_frames = Enum.map(frames, &{:text, Jason.encode!(&1)})
    {:push, encoded_frames, next_state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %{protocol: :websocket} = state) do
    close_connection(state.stats, state.source)
  end

  defp serve_wikimedia(connection, options) do
    bump(options.stats, :wikimedia, :requests)
    open_connection(options.stats, :wikimedia)

    try do
      connection = fetch_query_params(connection)
      first_sequence = replay_sequence(get_req_header(connection, "last-event-id"))

      if connection.query_params["once"] == "true" do
        {body, _next_sequence} = wikimedia_window(options, first_sequence)
        bump(options.stats, :wikimedia, :emitted_windows)

        connection
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, body)
      else
        connection =
          connection
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-store")
          |> send_chunked(200)

        stream_wikimedia(connection, options, first_sequence)
      end
    after
      close_connection(options.stats, :wikimedia)
    end
  end

  defp serve_request_fixture(connection, options, fixture_key, source) do
    bump(options.stats, source, :requests)
    json_response(connection, 200, fixture_payload(options, fixture_key))
  end

  defp stream_wikimedia(connection, options, first_sequence) do
    {body, next_sequence} = wikimedia_window(options, first_sequence)

    case chunk(connection, body) do
      {:ok, updated_connection} ->
        bump(options.stats, :wikimedia, :emitted_windows)

        receive do
        after
          options.cadence_ms -> stream_wikimedia(updated_connection, options, next_sequence)
        end

      {:error, :closed} ->
        connection

      {:error, _reason} ->
        connection
    end
  end

  defp wikimedia_window(options, first_sequence) do
    frames =
      for offset <- 0..2 do
        sequence = first_sequence + offset
        fixture = Enum.at(options.fixtures.wikimedia, rem(sequence - 1, 3))

        payload =
          put_in(
            fixture,
            ["meta", "dt"],
            options.clock.() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          )

        "id: wikimedia-#{sequence}\nevent: message\ndata: #{Jason.encode!(payload)}\n\n"
      end

    {IO.iodata_to_binary(frames), first_sequence + 3}
  end

  defp serve_fixture(connection, options, fixture_key, source \\ nil) do
    source = source || fixture_key
    bump(options.stats, source, :requests)
    bump(options.stats, source, :emitted_windows)
    json_response(connection, 200, fixture_payload(options, fixture_key))
  end

  defp fixture_payload(options, :usgs) do
    observed_at_milliseconds = options.clock.() |> DateTime.to_unix(:millisecond)

    features =
      options.fixtures.usgs["features"]
      |> Enum.with_index(1)
      |> Enum.map(fn {feature, index} ->
        put_in(
          feature,
          ["properties", "time"],
          observed_at_milliseconds + index * 1_000
        )
      end)

    options.fixtures.usgs
    |> put_in(["metadata", "generated"], observed_at_milliseconds)
    |> Map.put("features", features)
  end

  defp fixture_payload(options, :open_meteo) do
    observed_minute = Calendar.strftime(options.clock.(), "%Y-%m-%dT%H:%M")

    options.fixtures.open_meteo
    |> Stream.cycle()
    |> Enum.take(12)
    |> Enum.map(fn observation ->
      put_in(observation, ["current", "time"], observed_minute)
    end)
  end

  defp fixture_payload(options, fixture_key), do: Map.fetch!(options.fixtures, fixture_key)

  defp serve_drand_round(connection, encoded_round, options) do
    with {round, ""} when round > 0 <- Integer.parse(encoded_round) do
      fixture = options.fixtures.drand_round |> Map.put("round", round)
      bump(options.stats, :drand, :requests)
      bump(options.stats, :drand, :emitted_windows)
      json_response(connection, 200, fixture)
    else
      _invalid -> send_resp(connection, 404, "not found")
    end
  end

  defp upgrade_socket(connection, options, source, subscription?) do
    connection
    |> WebSockAdapter.upgrade(
      __MODULE__,
      %{
        protocol: :websocket,
        source: source,
        subscription?: subscription?,
        stats: options.stats,
        fixtures: options.fixtures,
        clock: options.clock,
        cadence_ms: options.cadence_ms,
        window_index: 0,
        window_scheduled?: false
      },
      timeout: @websocket_idle_timeout_ms
    )
    |> halt()
  end

  defp acknowledge_ripe_subscription(
         %{
           "type" => "ris_subscribe",
           "data" => %{
             "type" => "UPDATE",
             "host" => collector,
             "socketOptions" => %{"includeRaw" => false, "acknowledge" => true}
           }
         } = subscription,
         state
       )
       when map_size(subscription) == 2 and collector in ["rrc00.ripe.net", "rrc01.ripe.net"] do
    bump(state.stats, :ripe_ris, :subscriptions)

    acknowledgement = %{
      "type" => "ris_subscribe_ok",
      "data" => %{
        "subscription" => %{"type" => "UPDATE", "host" => collector},
        "socketOptions" => %{"includeRaw" => false, "acknowledge" => true}
      }
    }

    {:push, {:text, Jason.encode!(acknowledgement)}, schedule_window(state)}
  end

  defp acknowledge_ripe_subscription(_invalid, state), do: {:ok, state}

  defp schedule_window(%{window_scheduled?: true} = state), do: state

  defp schedule_window(state) do
    Process.send_after(self(), :emit_window, state.cadence_ms)
    %{state | window_scheduled?: true}
  end

  defp deterministic_window(%{source: :bluesky} = state) do
    base_microseconds =
      state.clock
      |> then(& &1.())
      |> DateTime.to_unix(:microsecond)

    state.fixtures.bluesky
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%{"time_us" => time} = frame, index} when is_integer(time) ->
        Map.put(frame, "time_us", base_microseconds + index * 100_000)

      {frame, _index} ->
        frame
    end)
  end

  defp deterministic_window(%{source: :ripe_ris} = state) do
    base_seconds =
      state.clock
      |> then(& &1.())
      |> DateTime.to_unix(:second)

    state.fixtures.ripe_ris
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%{"data" => %{"timestamp" => timestamp} = payload} = frame, index}
      when is_number(timestamp) ->
        payload =
          payload
          |> Map.put("timestamp", base_seconds + index / 10)
          |> Map.update("host", nil, &canonical_ripe_hostname/1)

        put_in(frame, ["data"], payload)

      {frame, _index} ->
        frame
    end)
  end

  defp deterministic_window(%{source: :solana} = state) do
    offset = state.window_index * 10

    Enum.map(state.fixtures.solana, fn frame ->
      frame
      |> update_in(["params", "result", "slot"], &(&1 + offset))
      |> update_in(["params", "result", "parent"], &(&1 + offset))
      |> update_in(["params", "result", "root"], &(&1 + offset))
    end)
  end

  defp canonical_ripe_hostname(<<"rrc", _suffix::binary-size(2)>> = collector),
    do: collector <> ".ripe.net"

  defp canonical_ripe_hostname(collector), do: collector

  defp replay_sequence([cursor]) do
    case Regex.run(~r/\Awikimedia-(\d+)\z/, cursor) do
      [_cursor, encoded_sequence] -> String.to_integer(encoded_sequence) + 1
      _invalid -> 1
    end
  end

  defp replay_sequence(_missing_or_ambiguous), do: 1

  defp valid_bluesky_subscription?(query) do
    String.contains?(query, "wantedCollections=app.bsky.feed.post") and
      String.contains?(query, "wantedCollections=app.bsky.feed.repost") and
      String.contains?(query, "maxMessageSizeBytes=262144") and
      String.contains?(query, "compress=false")
  end

  defp json_response(connection, status, body) do
    connection
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
  end

  defp bump(stats, source, counter) when source in @sources and counter in @counter_keys do
    source = Atom.to_string(source)
    counter = Atom.to_string(counter)

    Agent.update(stats, fn state ->
      update_in(state, [:counters, source, counter], &(&1 + 1))
    end)
  end

  defp open_connection(stats, source) when source in @sources do
    source = Atom.to_string(source)

    Agent.update(stats, fn state ->
      update_in(state, [:counters, source], fn counters ->
        active_connections = counters["active_connections"] + 1

        counters
        |> Map.update!("connection_opens", &(&1 + 1))
        |> Map.put("active_connections", active_connections)
        |> Map.update!("peak_connections", &max(&1, active_connections))
      end)
    end)
  end

  defp close_connection(stats, source) when source in @sources do
    source = Atom.to_string(source)

    Agent.update(stats, fn state ->
      update_in(state, [:counters, source, "active_connections"], &max(&1 - 1, 0))
    end)
  end

  defp initial_counters do
    Map.new(@sources, fn source ->
      {Atom.to_string(source), Map.new(@counter_keys, &{Atom.to_string(&1), 0})}
    end)
  end

  defp load_fixtures! do
    %{
      wikimedia: read_fixture!("wikimedia_frames.json"),
      usgs: read_fixture!("usgs.json"),
      open_meteo: read_fixture!("open_meteo.json"),
      bluesky: read_fixture!("bluesky_frames.json"),
      ripe_ris: read_fixture!("ripe_frames.json"),
      drand_chain_info: read_fixture!("drand_chain_info.json"),
      drand_round: read_fixture!("drand_rounds.json") |> List.first(),
      solana: read_fixture!("solana_slot_frames.json")
    }
  end

  defp read_fixture!(filename) do
    @fixture_directory
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
  end

  defp validate_options!(options) do
    options =
      options
      |> Keyword.validate!(
        clock: &DateTime.utc_now/0,
        cadence_ms: 1_000,
        port: 0,
        solana: false
      )
      |> Map.new()

    if is_function(options.clock, 0) and is_integer(options.cadence_ms) and
         options.cadence_ms > 0 and is_integer(options.port) and options.port in 0..65_535 and
         is_boolean(options.solana) do
      options
    else
      raise ArgumentError, "invalid fake upstream options"
    end
  end

  defp listener_port(server) do
    {:ok, {_address, port}} = server |> child_pid(:bandit) |> ThousandIsland.listener_info()
    port
  end

  defp child_pid(server, id) do
    case List.keyfind(Supervisor.which_children(server), id, 0) do
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      nil -> raise ArgumentError, "fake upstream child #{inspect(id)} is unavailable"
    end
  end
end
