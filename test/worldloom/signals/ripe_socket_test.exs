defmodule Worldloom.Signals.RipeSocketTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.CoordinatorTestStore
  alias Worldloom.Loom.Event
  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Loom.Instruction
  alias Worldloom.Loom.Store
  alias Worldloom.Repo
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.RipeSocket
  alias Worldloom.TestSupport.FakeWebSocketTransport
  alias Worldloom.TestSupport.WebSocketFixtureServer

  @ca_file Path.expand("test/support/fixtures/tls/localhost_ca.pem")
  @fixture Path.expand("test/support/fixtures/feeds/ripe_frames.json")
  @first_external_id "ripe-window:1786204802:4"
  @second_external_id "ripe-window:1786204806:4"

  test "persists privacy-safe windows through a real WSS edge and reports a reconnect gap" do
    test_process = self()
    attach_vertical_telemetry(test_process)
    start_independent_store()
    context = start_real_edge(~U[2026-08-08 16:00:03.500000Z], test_process)
    source_owner = context.socket
    first_connection = negotiate_real_edge(context)
    [first_frame, second_collector_frame | _remaining] = read_frames()

    captured_log =
      capture_log(fn ->
        push_provider_frames(first_connection, [first_frame, second_collector_frame])

        assert eventually(fn ->
                 state = :sys.get_state(source_owner)
                 observation = HealthRegistry.current(context.health).ripe_ris

                 state.window.announced == 4 and state.window.withdrawn == 3 and
                   observation.drops == 0
               end)

        set_real_clock(context.clock, ~U[2026-08-08 16:00:07Z])
        send(source_owner, :flush_window)
        drain_vertical_once(context.buffer)

        assert Repo.get!(FeedCheckpoint, "ripe_ris")
               |> Map.take([:cursor, :last_successful_at, :metadata]) == %{
                 cursor: nil,
                 last_successful_at: ~U[2026-08-08 16:00:07.000000Z],
                 metadata: %{}
               }

        push_provider_frames(first_connection, [
          %{
            "type" => "ris_error",
            "data" => %{"message" => "synthetic-slow-consumer-private"}
          }
        ])

        send(first_connection, {:close, 1_013, "synthetic-private-slow-consumer-close"})

        assert_receive {:vertical_socket_timer, ^source_owner, {:connect, reconnect_token},
                        delay},
                       1_000

        assert delay in 1_000..300_000

        assert eventually(fn ->
                 observation = HealthRegistry.current(context.health).ripe_ris

                 observation.connection == :disconnected and
                   observation.last_reason == :replay
               end)

        send(source_owner, {:connect, reconnect_token})
        second_connection = negotiate_real_edge(context)
        assert first_connection != second_connection
        assert Process.alive?(source_owner)

        replay_free_frame = at(first_frame, ~U[2026-08-08 16:00:07.500000Z])
        push_provider_frames(second_connection, [replay_free_frame])

        assert eventually(fn ->
                 state = :sys.get_state(source_owner)
                 state.window.announced == 3 and state.window.withdrawn == 2
               end)

        set_real_clock(context.clock, ~U[2026-08-08 16:00:11Z])
        send(source_owner, :flush_window)
        drain_vertical_once(context.buffer)
      end)

    rows =
      Repo.all(
        from event in Event,
          where: event.external_id in [@first_external_id, @second_external_id],
          order_by: [asc: event.occurred_at]
      )

    assert Enum.map(rows, & &1.external_id) == [@first_external_id, @second_external_id]
    assert Enum.map(rows, & &1.payload["announced"]) == [4, 3]
    assert Enum.map(rows, & &1.payload["withdrawn"]) == [3, 2]
    assert Enum.map(rows, & &1.payload["window_count"]) == [1, 1]
    assert Enum.map(rows, & &1.payload["window_span_seconds"]) == [4, 4]

    assert Repo.get!(FeedCheckpoint, "ripe_ris")
           |> Map.take([:cursor, :last_successful_at, :metadata]) == %{
             cursor: nil,
             last_successful_at: ~U[2026-08-08 16:00:11.000000Z],
             metadata: %{}
           }

    browser_instructions = Enum.map(rows, &Instruction.from_event/1)

    public_surface =
      inspect({rows, browser_instructions, Coordinator.current_snapshot(context.coordinator)})

    operational_surface =
      inspect({:sys.get_state(source_owner), HealthRegistry.current(context.health)})

    telemetry_surface = context |> vertical_telemetry() |> inspect()

    private_markers = [
      "rrc00",
      "rrc01",
      "192.0.2.10",
      "2001:db8:ffff::10",
      "64496",
      "64497",
      "203.0.113.0/24",
      "2001:db8:300::/48",
      "synthetic-message-alpha",
      "synthetic-message-beta",
      "synthetic-raw-bytes-never-retained",
      "synthetic-slow-consumer-private",
      "synthetic-private-slow-consumer-close"
    ]

    for marker <- private_markers do
      refute public_surface =~ marker
      refute operational_surface =~ marker
      refute telemetry_surface =~ marker
      refute captured_log =~ marker
    end
  end

  test "requests collectors first and sends one exact bounded subscription per intersection" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)

    assert_receive {:transport_sent, ^transport_id, {:text, request}}, 500
    assert Jason.decode!(request) == %{"type" => "request_rrc_list", "data" => nil}

    rrc_list = %{"type" => "ris_rrc_list", "data" => ["rrc00", "rrc01", "rrc02"]}
    send_text(context.socket, transport_id, rrc_list)

    assert_receive {:transport_sent, ^transport_id, {:text, first_subscription}}, 500
    assert_receive {:transport_sent, ^transport_id, {:text, second_subscription}}, 500

    assert Enum.map([first_subscription, second_subscription], &Jason.decode!/1) == [
             subscription("rrc00"),
             subscription("rrc01")
           ]

    refute_receive {:transport_sent, ^transport_id, {:text, _third_subscription}}, 50

    assert {:max_heap_size, heap_policy} = Process.info(context.socket, :max_heap_size)

    assert Map.take(heap_policy, [:size, :kill, :error_logger]) ==
             %{size: 2_000_000, kill: true, error_logger: false}
  end

  test "accepts each exact subscription acknowledgement once and fails duplicates closed" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)
    assert_receive {:timer_scheduled, {:subscription_timeout, generation}, 5_000}, 500
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500
    send_text(context.socket, transport_id, %{"type" => "ris_rrc_list", "data" => ["rrc00"]})
    assert_receive {:transport_sent, ^transport_id, {:text, encoded_subscription}}, 500
    acknowledgement = encoded_subscription |> Jason.decode!() |> subscription_acknowledgement()

    send_text(context.socket, transport_id, acknowledgement)

    assert eventually(fn ->
             state = :sys.get_state(context.socket)

             state.pending_acknowledgements == MapSet.new() and
               HealthRegistry.current(context.health).ripe_ris.drops == 0
           end)

    send(context.socket, {:subscription_timeout, generation})
    refute_receive {:transport_closed, ^transport_id}, 50
    assert :sys.get_state(context.socket).subscribed?

    send_text(context.socket, transport_id, acknowledgement)
    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).ripe_ris

             observation.connection == :disconnected and
               observation.last_reason == :subscription
           end)
  end

  test "fails an update before every subscription acknowledgement closed" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500

    send_text(context.socket, transport_id, %{
      "type" => "ris_rrc_list",
      "data" => ["rrc00", "rrc01"]
    })

    assert_receive {:transport_sent, ^transport_id, {:text, first_subscription}}, 500
    assert_receive {:transport_sent, ^transport_id, {:text, _second_subscription}}, 500

    send_text(
      context.socket,
      transport_id,
      first_subscription |> Jason.decode!() |> subscription_acknowledgement()
    )

    assert eventually(fn ->
             state = :sys.get_state(context.socket)
             not state.subscribed? and MapSet.size(state.pending_acknowledgements) == 1
           end)

    [frame | _remaining] = read_frames()
    send_text(context.socket, transport_id, frame)
    assert_receive {:transport_closed, ^transport_id}, 500
    refute_receive {:buffer_submit, _events, _checkpoint}, 50

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).ripe_ris

             observation.connection == :disconnected and
               observation.last_reason == :subscription
           end)
  end

  test "fails a missing subscription acknowledgement closed after a bounded deadline" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)

    assert_receive {:timer_scheduled, {:subscription_timeout, generation}, 5_000}, 500
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500
    send_text(context.socket, transport_id, %{"type" => "ris_rrc_list", "data" => ["rrc00"]})
    assert_receive {:transport_sent, ^transport_id, {:text, _subscription}}, 500

    send(context.socket, {:subscription_timeout, generation})
    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).ripe_ris

             observation.connection == :disconnected and
               observation.last_reason == :subscription
           end)
  end

  test "fails a malformed subscription acknowledgement closed without retaining it" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500
    send_text(context.socket, transport_id, %{"type" => "ris_rrc_list", "data" => ["rrc00"]})
    assert_receive {:transport_sent, ^transport_id, {:text, encoded_subscription}}, 500

    malformed_acknowledgement =
      encoded_subscription
      |> Jason.decode!()
      |> subscription_acknowledgement()
      |> put_in(["data", "private"], "provider-ack-secret")

    send_text(context.socket, transport_id, malformed_acknowledgement)
    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).ripe_ris

             observation.connection == :disconnected and
               observation.last_reason == :subscription
           end)

    refute inspect(:sys.get_state(context.socket)) =~ "provider-ack-secret"
  end

  test "fails an acknowledgement for an unrequested collector closed" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500
    send_text(context.socket, transport_id, %{"type" => "ris_rrc_list", "data" => ["rrc00"]})
    assert_receive {:transport_sent, ^transport_id, {:text, _encoded_subscription}}, 500

    send_text(
      context.socket,
      transport_id,
      subscription("rrc01") |> subscription_acknowledgement()
    )

    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).ripe_ris

             observation.connection == :disconnected and
               observation.last_reason == :subscription
           end)
  end

  test "authorizes only collectors in the negotiated intersection" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500
    send_text(context.socket, transport_id, %{"type" => "ris_rrc_list", "data" => ["rrc00"]})
    assert_receive {:transport_sent, ^transport_id, {:text, encoded_subscription}}, 500

    send_text(
      context.socket,
      transport_id,
      encoded_subscription |> Jason.decode!() |> subscription_acknowledgement()
    )

    assert eventually(fn -> :sys.get_state(context.socket).subscribed? end)
    [frame | _remaining] = read_frames()
    unsolicited = put_in(frame, ["data", "host"], "rrc01")

    send_text(context.socket, transport_id, unsolicited)

    assert eventually(fn ->
             state = :sys.get_state(context.socket)

             state.window.announced == 0 and
               HealthRegistry.current(context.health).ripe_ris.last_reason == :malformed
           end)

    send_text(context.socket, transport_id, frame)
    assert eventually(fn -> :sys.get_state(context.socket).window.announced == 3 end)
  end

  test "reduces complete RIPE updates with one receipt time and persists only aggregates" do
    now = ~U[2026-08-08 16:00:03.500000Z]
    context = start_socket(now)
    {transport_id, context} = connect_and_subscribe(context)
    reset_clock_count(context.clock)
    [frame | _remaining] = read_frames()

    send_text(context.socket, transport_id, frame)

    assert eventually(fn -> :sys.get_state(context.socket).window.announced == 3 end)

    assert eventually(fn ->
             HealthRegistry.current(context.health).ripe_ris.last_contact_at == now
           end)

    assert clock_count(context.clock) == 1

    set_clock(context.clock, ~U[2026-08-08 16:00:08Z])
    send(context.socket, :flush_window)

    assert_receive {:buffer_submit, [event], checkpoint}, 500
    assert event.source == :ripe_ris
    assert event.payload["announced"] == 3
    assert event.payload["withdrawn"] == 2
    assert event.payload["collector_observations"] == 1
    assert event.payload["peer_observations"] == 1

    assert checkpoint == %{
             source: "ripe_ris",
             cursor: nil,
             etag: nil,
             last_successful_at: ~U[2026-08-08 16:00:08Z],
             metadata: %{}
           }

    inspected = inspect(:sys.get_state(context.socket))

    for marker <- ["192.0.2.10", "synthetic-message-alpha", "synthetic-raw-bytes-never-retained"] do
      refute inspected =~ marker
    end
  end

  test "closes durably and retries the same complete frame with the same receipt time" do
    context = start_socket(~U[2026-08-08 16:00:02Z])
    {transport_id, context} = connect_and_subscribe(context)
    set_clock(context.clock, ~U[2026-08-08 16:00:08Z])
    reset_clock_count(context.clock)
    [frame | _remaining] = read_frames()
    frame = put_in(frame, ["data", "timestamp"], 1_786_204_808.0)

    send_text(context.socket, transport_id, frame)

    assert_receive {:buffer_submit, [], empty_checkpoint}, 500
    assert empty_checkpoint.last_successful_at == ~U[2026-08-08 16:00:08Z]
    assert clock_count(context.clock) == 1

    set_clock(context.clock, ~U[2026-08-08 16:00:12Z])
    send(context.socket, :flush_window)
    assert_receive {:buffer_submit, [event], _checkpoint}, 500
    assert event.payload["announced"] == 3
  end

  test "does not install a closed successor when durability fails" do
    buffer = fn _events, _checkpoint -> {:error, :unavailable} end
    context = start_socket(~U[2026-08-08 16:00:03Z], buffer: buffer)
    {transport_id, context} = connect_and_subscribe(context)
    [frame | _remaining] = read_frames()
    send_text(context.socket, transport_id, frame)
    assert eventually(fn -> :sys.get_state(context.socket).window.announced == 3 end)
    prior_window = :sys.get_state(context.socket).window

    set_clock(context.clock, ~U[2026-08-08 16:00:08Z])
    send(context.socket, :flush_window)

    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             state = :sys.get_state(context.socket)

             state.window == prior_window and
               HealthRegistry.current(context.health).ripe_ris.last_reason == :persistence
           end)
  end

  test "grows backoff across repeated provider handshake failures" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {first_id, context} = connect(context)
    assert_receive {:transport_sent, ^first_id, {:text, _request}}, 500
    send_text(context.socket, first_id, %{"type" => "ris_rrc_list", "data" => ["rrc99"]})

    assert_receive {:timer_scheduled, {:connect, first_token}, 1_000}, 500
    send(context.socket, {:connect, first_token})
    assert_receive {:transport_connect, _endpoint, second_id}, 500
    send(context.socket, {:fake_socket, second_id, [:connected]})
    assert_receive {:transport_sent, ^second_id, {:text, _request}}, 500
    send_text(context.socket, second_id, %{"type" => "ris_rrc_list", "data" => ["rrc99"]})

    assert_receive {:timer_scheduled, {:connect, _second_token}, 2_000}, 500
  end

  test "fails a missing collector intersection closed without exposing provider details" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500

    send_text(context.socket, transport_id, %{
      "type" => "ris_rrc_list",
      "data" => ["rrc98", "rrc99"],
      "private" => "provider-secret"
    })

    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).ripe_ris
             observation.connection == :disconnected and observation.last_reason == :subscription
           end)

    refute inspect(:sys.get_state(context.socket)) =~ "provider-secret"
  end

  test "acknowledges provider close before reconnecting" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect_and_subscribe(context)

    send(context.socket, {:fake_socket, transport_id, [{:close, 1_001, "private-reason"}]})

    assert_receive {:transport_acknowledged_close, ^transport_id, 1_001}, 500
    assert_receive {:timer_scheduled, {:connect, _token}, delay}, 500
    assert delay in 1_000..300_000

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).ripe_ris
             observation.connection == :disconnected and observation.last_reason == :replay
           end)

    refute inspect(:sys.get_state(context.socket)) =~ "private-reason"
  end

  test "handles control, malformed, binary, stale, and mailbox input without harming siblings" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    sibling = start_supervised!({Task, fn -> Process.sleep(:infinity) end})
    {transport_id, context} = connect_and_subscribe(context)

    send(context.socket, {:fake_socket, transport_id, [{:ping, "pulse"}]})
    assert_receive {:transport_sent, ^transport_id, {:pong, "pulse"}}, 500

    send(context.socket, {:fake_socket, transport_id, [{:text, "{malformed"}]})

    assert eventually(fn ->
             HealthRegistry.current(context.health).ripe_ris.last_reason == :malformed
           end)

    send(context.socket, {:fake_socket, transport_id, [{:binary, "private"}]})
    assert_receive {:transport_closed, ^transport_id}, 500

    send(
      context.socket,
      {:fake_socket, transport_id, [{:text, Jason.encode!(hd(read_frames()))}]}
    )

    refute_receive {:buffer_submit, _events, _checkpoint}, 50

    :ok = :sys.suspend(context.socket)
    monitor = Process.monitor(context.socket)
    Enum.each(1..102, fn _index -> send(context.socket, :mailbox_pressure) end)
    :ok = :sys.resume(context.socket)

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 500

    assert eventually(fn ->
             HealthRegistry.current(context.health).ripe_ris.last_reason == :mailbox
           end)

    refute Process.alive?(context.socket)
    assert Process.alive?(sibling)
  end

  defp start_real_edge(now, test_process) do
    clock = start_supervised!({Agent, fn -> now end})

    health =
      start_supervised!(
        {HealthRegistry, name: nil, monitor: nil, clock: fn -> Agent.get(clock, & &1) end}
      )

    coordinator =
      start_supervised!(
        {Coordinator,
         name: nil,
         bootstrap: :empty,
         store: CoordinatorTestStore,
         topic: "loom:ripe-vertical:#{System.unique_integer([:positive, :monotonic])}"}
      )

    buffer =
      start_supervised!(
        {Buffer,
         name: nil,
         coordinator: coordinator,
         health_registry: health,
         clock: fn -> Agent.get(clock, &DateTime.to_unix(&1, :millisecond)) end,
         timer: fn destination, message, delay ->
           send(test_process, {:vertical_buffer_timer, destination, message, delay})
           make_ref()
         end}
      )

    server =
      start_supervised!(
        {WebSocketFixtureServer, test_process: test_process, record_requests: true}
      )

    socket =
      start_supervised!(
        {RipeSocket,
         name: nil,
         url: WebSocketFixtureServer.endpoint(server),
         collectors: ["rrc00", "rrc01"],
         transport_options: [cacertfile: @ca_file],
         buffer: fn events, checkpoint -> Buffer.submit(buffer, events, checkpoint) end,
         health_registry: health,
         clock: fn -> Agent.get(clock, & &1) end,
         random: fn -> 0.5 end,
         timer: fn destination, message, delay ->
           send(test_process, {:vertical_socket_timer, destination, message, delay})
           make_ref()
         end}
      )

    %{
      socket: socket,
      server: server,
      buffer: buffer,
      coordinator: coordinator,
      health: health,
      clock: clock
    }
  end

  defp negotiate_real_edge(context) do
    assert_receive {:fixture_request, "/socket", query}, 1_000
    assert query == ""
    assert_receive {:fixture_connected, connection}, 1_000
    assert receive_client_json() == %{"type" => "request_rrc_list", "data" => nil}

    push_provider_frames(connection, [
      %{"type" => "ris_rrc_list", "data" => ["rrc00", "rrc01", "rrc02"]}
    ])

    subscriptions = [receive_client_json(), receive_client_json()]
    assert subscriptions == [subscription("rrc00"), subscription("rrc01")]

    push_provider_frames(connection, Enum.map(subscriptions, &subscription_acknowledgement/1))

    assert eventually(fn ->
             state = :sys.get_state(context.socket)

             state.subscribed? and state.pending_acknowledgements == MapSet.new() and
               HealthRegistry.current(context.health).ripe_ris.connection == :connected
           end)

    connection
  end

  defp receive_client_json do
    assert_receive {:fixture_frame, :text, encoded}, 1_000
    Jason.decode!(encoded)
  end

  defp subscription_acknowledgement(%{"data" => subscription}) do
    %{
      "type" => "ris_subscribe_ok",
      "data" => %{
        "subscription" => Map.drop(subscription, ["socketOptions"]),
        "socketOptions" => Map.fetch!(subscription, "socketOptions")
      }
    }
  end

  defp push_provider_frames(connection, frames) do
    barrier = "fixture-barrier-#{System.unique_integer([:positive, :monotonic])}"
    encoded = Enum.map(frames, &{:text, Jason.encode!(&1)})
    send(connection, {:push_many, encoded ++ [{:ping, barrier}]})
    assert_receive {:fixture_control, :pong, ^barrier}, 1_000
  end

  defp attach_vertical_telemetry(test_process) do
    handler_id = "ripe-vertical-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:worldloom, :loom, :coordinator, :start],
          [:worldloom, :loom, :commit],
          [:worldloom, :signals, :feed],
          [:worldloom, :signals, :retry],
          [:worldloom, :signals, :health],
          [:worldloom, :signals, :buffer, :depth]
        ],
        fn event, measurements, metadata, owner ->
          send(owner, {:vertical_telemetry, event, measurements, metadata})
        end,
        test_process
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp vertical_telemetry(_context, messages \\ []) do
    receive do
      {:vertical_telemetry, event, measurements, metadata} ->
        vertical_telemetry(nil, [{event, measurements, metadata} | messages])
    after
      10 -> Enum.reverse(messages)
    end
  end

  defp start_independent_store do
    original_repo = Repo.get_dynamic_repo()

    {:ok, independent_repo} =
      Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 4)

    Process.unlink(independent_repo)
    Repo.put_dynamic_repo(independent_repo)
    clear_vertical_slice_rows()

    on_exit(fn ->
      if Process.alive?(independent_repo) do
        Repo.put_dynamic_repo(independent_repo)
        clear_vertical_slice_rows()
        Supervisor.stop(independent_repo)
      end

      Repo.put_dynamic_repo(original_repo)
    end)

    start_supervised!({CoordinatorTestStore, delegate: Store, repo: independent_repo})
  end

  defp clear_vertical_slice_rows do
    Repo.delete_all(
      from event in Event,
        where: event.external_id in [@first_external_id, @second_external_id]
    )

    Repo.delete_all(from checkpoint in FeedCheckpoint, where: checkpoint.source == "ripe_ris")
  end

  defp drain_vertical_once(buffer) do
    assert_receive {:vertical_buffer_timer, ^buffer, {:drain, _token} = message, 250}, 1_000
    send(buffer, message)
    assert eventually(fn -> Buffer.depth(buffer) == 0 end)
  end

  defp at(frame, occurred_at) do
    put_in(frame, ["data", "timestamp"], DateTime.to_unix(occurred_at, :microsecond) / 1_000_000)
  end

  defp set_real_clock(clock, now), do: Agent.update(clock, fn _previous -> now end)

  defp start_socket(now, options \\ []) do
    test_process = self()
    clock = start_supervised!({Agent, fn -> %{now: now, count: 0} end})

    health =
      start_supervised!(
        {HealthRegistry, name: nil, monitor: nil, clock: fn -> Agent.get(clock, & &1.now) end}
      )

    buffer =
      Keyword.get(options, :buffer, fn events, checkpoint ->
        send(test_process, {:buffer_submit, events, checkpoint})
        :ok
      end)

    timer = fn _destination, message, delay ->
      send(test_process, {:timer_scheduled, message, delay})
      make_ref()
    end

    socket =
      start_supervised!(
        {RipeSocket,
         name: nil,
         url: "wss://ris.example.invalid/socket?token=discarded",
         collectors: ["rrc00", "rrc01"],
         transport: FakeWebSocketTransport,
         transport_options: [owner: test_process],
         buffer: buffer,
         health_registry: health,
         clock: clock_fun(clock),
         random: fn -> 0.5 end,
         timer: timer}
      )

    %{socket: socket, health: health, clock: clock}
  end

  defp connect(context) do
    assert_receive {:transport_connect, endpoint, transport_id}, 500
    assert endpoint == "wss://ris.example.invalid/socket?token=discarded"
    send(context.socket, {:fake_socket, transport_id, [:connected]})
    {transport_id, context}
  end

  defp connect_and_subscribe(context) do
    {transport_id, context} = connect(context)
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500
    send_text(context.socket, transport_id, %{"type" => "ris_rrc_list", "data" => ["rrc00"]})
    assert_receive {:transport_sent, ^transport_id, {:text, encoded_subscription}}, 500

    send_text(
      context.socket,
      transport_id,
      encoded_subscription |> Jason.decode!() |> subscription_acknowledgement()
    )

    assert eventually(fn -> :sys.get_state(context.socket).subscribed? end)
    {transport_id, context}
  end

  defp send_text(socket, transport_id, payload) do
    send(socket, {:fake_socket, transport_id, [{:text, Jason.encode!(payload)}]})
  end

  defp subscription(collector) do
    %{
      "type" => "ris_subscribe",
      "data" => %{
        "type" => "UPDATE",
        "host" => collector,
        "socketOptions" => %{"includeRaw" => false, "acknowledge" => true}
      }
    }
  end

  defp read_frames do
    @fixture |> File.read!() |> Jason.decode!()
  end

  defp clock_fun(clock) do
    fn ->
      Agent.get_and_update(clock, fn state -> {state.now, %{state | count: state.count + 1}} end)
    end
  end

  defp set_clock(clock, now), do: Agent.update(clock, &%{&1 | now: now})
  defp reset_clock_count(clock), do: Agent.update(clock, &%{&1 | count: 0})
  defp clock_count(clock), do: Agent.get(clock, & &1.count)

  defp eventually(assertion, attempts \\ 50)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    if assertion.() do
      true
    else
      Process.sleep(5)
      eventually(assertion, attempts - 1)
    end
  end
end
