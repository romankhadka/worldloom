defmodule Worldloom.TestSupport.BalancedWorldHarness do
  @moduledoc """
  Starts the real test application against one local, instrumented upstream.

  This module is compiled only in the test environment. It keeps provider
  simulation server-owned while real browsers and LiveViews use the public app.
  """

  alias Worldloom.Signals.BlueskySocket
  alias Worldloom.Signals.DrandWorker
  alias Worldloom.Signals.EarthquakeWorker
  alias Worldloom.Signals.HealthMonitor
  alias Worldloom.Signals.RipeSocket
  alias Worldloom.Signals.SolanaSocket
  alias Worldloom.Signals.WeatherWorker
  alias Worldloom.Signals.WikimediaWorker
  alias Worldloom.TestSupport.BalancedWorldHarness.DrandClient, as: HarnessDrandClient
  alias Worldloom.TestSupport.FakeUpstream

  @default_port 4443
  @default_cadence_ms 1_000

  @spec start!(keyword()) :: %{fake_upstream: pid(), urls: map()}
  def start!(options \\ []) do
    options = validate_options!(options)
    ensure_application_stopped!()
    configure_test_endpoint!()
    disable_automatic_ingestion!()
    {:ok, _applications} = Application.ensure_all_started(:worldloom)

    fake_upstream =
      start_fake_upstream!(Worldloom.Supervisor,
        port: options.port,
        cadence_ms: options.cadence_ms
      )

    urls = FakeUpstream.urls(fake_upstream)
    :ok = :public_key.cacerts_load(FakeUpstream.ca_file())
    Application.put_env(:worldloom, Worldloom.Signals, signal_config(urls))

    restart_health_monitor!()
    start_source_children!(source_children(urls))
    announce_ready(urls)

    %{fake_upstream: fake_upstream, urls: urls}
  end

  @doc false
  @spec start_fake_upstream!(Supervisor.supervisor(), keyword()) :: pid()
  def start_fake_upstream!(supervisor, options) when is_list(options) do
    fake_options = Keyword.put(options, :solana, true)
    {:ok, fake_upstream} = Supervisor.start_child(supervisor, {FakeUpstream, fake_options})
    fake_upstream
  end

  @doc false
  @spec signal_config(map()) :: Worldloom.Signals.Config.t()
  def signal_config(urls) when is_map(urls) do
    config = Application.fetch_env!(:worldloom, Worldloom.Signals)

    %{
      config
      | enabled: true,
        wikimedia_url: Map.fetch!(urls, :wikimedia),
        usgs_url: Map.fetch!(urls, :usgs),
        open_meteo_url: Map.fetch!(urls, :open_meteo),
        earthquake_interval_ms: @default_cadence_ms,
        weather_interval_ms: @default_cadence_ms,
        drand_enabled: true,
        bluesky_enabled: true,
        bluesky_url: Map.fetch!(urls, :bluesky),
        ripe_enabled: true,
        ripe_url: Map.fetch!(urls, :ripe_ris),
        ripe_collectors: ["rrc00", "rrc01"],
        solana_enabled: true,
        solana_url: Map.fetch!(urls, :solana)
    }
  end

  @doc false
  @spec source_children(map(), keyword()) :: [Supervisor.child_spec() | tuple()]
  def source_children(urls, options \\ []) when is_map(urls) and is_list(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)
    ca_file = FakeUpstream.ca_file()
    transport_options = [cacertfile: ca_file]
    drand_client = HarnessDrandClient.new(Map.fetch!(urls, :drand_origin), ca_file, clock)

    [
      {Task.Supervisor, name: Worldloom.Signals.StreamSupervisor},
      {WikimediaWorker,
       url: Map.fetch!(urls, :wikimedia),
       task_supervisor: Worldloom.Signals.StreamSupervisor,
       clock: clock},
      {EarthquakeWorker,
       url: Map.fetch!(urls, :usgs), interval_ms: @default_cadence_ms, clock: clock},
      {WeatherWorker,
       url: Map.fetch!(urls, :open_meteo), interval_ms: @default_cadence_ms, clock: clock},
      {DrandWorker, client: drand_client, client_module: HarnessDrandClient, clock: clock},
      {BlueskySocket,
       url: Map.fetch!(urls, :bluesky), transport_options: transport_options, clock: clock},
      {RipeSocket,
       url: Map.fetch!(urls, :ripe_ris),
       collectors: ["rrc00", "rrc01"],
       transport_options: transport_options,
       clock: clock},
      {SolanaSocket,
       url: Map.fetch!(urls, :solana), transport_options: transport_options, clock: clock}
    ]
  end

  defp validate_options!(options) do
    options =
      options
      |> Keyword.validate!(port: @default_port, cadence_ms: @default_cadence_ms)
      |> Map.new()

    if options.port in 1..65_535 and is_integer(options.cadence_ms) and options.cadence_ms > 0 do
      options
    else
      raise ArgumentError, "balanced-world harness requires a valid port and positive cadence"
    end
  end

  defp ensure_application_stopped! do
    if Process.whereis(Worldloom.Supervisor) do
      raise "start the balanced-world harness with mix run --no-start"
    end
  end

  defp configure_test_endpoint! do
    endpoint_config = Application.fetch_env!(:worldloom, WorldloomWeb.Endpoint)

    Application.put_env(
      :worldloom,
      WorldloomWeb.Endpoint,
      Keyword.put(endpoint_config, :server, true)
    )
  end

  defp disable_automatic_ingestion! do
    config = Application.fetch_env!(:worldloom, Worldloom.Signals)

    Application.put_env(
      :worldloom,
      Worldloom.Signals,
      %{
        config
        | enabled: false,
          drand_enabled: false,
          bluesky_enabled: false,
          ripe_enabled: false,
          solana_enabled: false
      }
    )
  end

  defp restart_health_monitor! do
    :ok = Supervisor.terminate_child(Worldloom.Supervisor, HealthMonitor)
    :ok = Supervisor.delete_child(Worldloom.Supervisor, HealthMonitor)
    {:ok, _monitor} = Supervisor.start_child(Worldloom.Supervisor, {HealthMonitor, enabled: true})
  end

  defp start_source_children!(children) do
    Enum.each(children, fn child ->
      {:ok, _process} = Supervisor.start_child(Worldloom.Signals.Supervisor, child)
    end)
  end

  defp announce_ready(urls) do
    IO.puts("Worldloom balanced-world test server: http://localhost:4002")
    IO.puts("Instrumented upstream stats: #{urls.stats}")
  end
end

defmodule Worldloom.TestSupport.BalancedWorldHarness.DrandClient do
  @moduledoc false

  @chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
  @period 3

  @enforce_keys [:origin, :cacertfile, :genesis_time]
  defstruct @enforce_keys

  @spec new(String.t(), String.t(), (-> DateTime.t())) :: struct()
  def new(origin, cacertfile, clock)
      when is_binary(origin) and is_binary(cacertfile) and is_function(clock, 0) do
    genesis_time = clock.() |> DateTime.to_unix(:second) |> Kernel.-(@period)
    %__MODULE__{origin: origin, cacertfile: cacertfile, genesis_time: genesis_time}
  end

  @spec schedule(struct()) :: %{period: 3, genesis_time: pos_integer()}
  def schedule(%__MODULE__{genesis_time: genesis_time}) do
    %{period: @period, genesis_time: genesis_time}
  end

  @spec fetch_round(struct(), pos_integer()) ::
          {:ok, %{round: pos_integer(), render_identity: String.t()}}
          | {:error, :unavailable}
  def fetch_round(%__MODULE__{} = client, round) when is_integer(round) and round > 0 do
    url = client.origin <> "/v2/chains/#{@chain_hash}/rounds/#{round}"

    case Req.get(url,
           connect_options: [
             protocols: [:http1],
             transport_opts: [cacertfile: client.cacertfile]
           ],
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"round" => ^round, "signature" => signature}}}
      when is_binary(signature) and byte_size(signature) == 96 ->
        with true <- Regex.match?(~r/\A[0-9a-f]{96}\z/, signature),
             {:ok, signature_bytes} <- Base.decode16(signature, case: :lower) do
          render_identity =
            signature_bytes
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)

          {:ok, %{round: round, render_identity: render_identity}}
        else
          _invalid -> {:error, :unavailable}
        end

      _unavailable ->
        {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def fetch_round(%__MODULE__{}, _invalid), do: {:error, :unavailable}
end
