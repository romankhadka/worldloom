defmodule Worldloom.Signals.BlueskySocketTest do
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
  alias Worldloom.Signals.BlueskySocket
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.TestSupport.FakeWebSocketTransport
  alias Worldloom.TestSupport.WebSocketFixtureServer

  @ca_file Path.expand("test/support/fixtures/tls/localhost_ca.pem")
  @fixture Path.expand("test/support/fixtures/feeds/bluesky_frames.json")
  @first_external_id "bluesky-window:1786204801:4"
  @second_external_id "bluesky-window:1786204805:4"

  test "persists privacy-safe windows through a real WSS edge and deduplicates reconnect overlap" do
    test_process = self()
    attach_vertical_telemetry(test_process)
    start_independent_store()
    context = start_real_edge(~U[2026-08-08 16:00:03.500000Z], test_process)
    source_owner = context.socket

    assert_receive {:fixture_request, "/socket", first_query}, 1_000
    assert_subscription_query(first_query, nil)
    assert_receive {:fixture_connected, first_connection}, 1_000

    assert eventually(fn ->
             HealthRegistry.current(context.health).bluesky.connection == :connected
           end)

    [private_frame | fixture_frames] = read_frames()
    identity_frame = Enum.find(fixture_frames, &(&1["kind"] == "identity"))
    account_frame = Enum.find(fixture_frames, &(&1["kind"] == "account"))
    first_frame = at(private_frame, ~U[2026-08-08 16:00:03.500000Z])
    second_frame = at(private_frame, ~U[2026-08-08 16:00:07.500000Z])

    captured_log =
      capture_log(fn ->
        push_frames(first_connection, [first_frame, identity_frame, account_frame])

        assert eventually(fn ->
                 state = :sys.get_state(source_owner)
                 observation = HealthRegistry.current(context.health).bluesky
                 state.window.total_actions == 1 and observation.drops == 2
               end)

        set_real_clock(context.clock, ~U[2026-08-08 16:00:06Z])
        send(source_owner, :flush_window)
        drain_vertical_once(context.buffer)

        assert eventually(fn ->
                 :sys.get_state(source_owner).committed_cursor == first_frame["time_us"]
               end)

        assert Repo.get!(FeedCheckpoint, "bluesky").cursor ==
                 Integer.to_string(first_frame["time_us"])

        set_real_clock(context.clock, ~U[2026-08-08 16:00:07.500000Z])
        push_frames(first_connection, [second_frame])

        assert eventually(fn ->
                 :sys.get_state(source_owner).window.total_actions == 1
               end)

        send(first_connection, {:close, 1_001, "fixture restart"})

        assert_receive {:vertical_socket_timer, ^source_owner, {:connect, reconnect_token},
                        delay},
                       1_000

        assert delay in 1_000..300_000
        send(source_owner, {:connect, reconnect_token})

        assert_receive {:fixture_request, "/socket", replay_query}, 1_000
        assert_subscription_query(replay_query, first_frame["time_us"] - 5_000_000)
        assert_receive {:fixture_connected, second_connection}, 1_000
        assert first_connection != second_connection
        assert source_owner == context.socket
        assert Process.alive?(source_owner)

        assert eventually(
                 fn ->
                   HealthRegistry.current(context.health).bluesky.connection == :connected
                 end,
                 200
               )

        push_frames(second_connection, [first_frame, second_frame])

        assert eventually(fn ->
                 state = :sys.get_state(source_owner)
                 observation = HealthRegistry.current(context.health).bluesky

                 state.window.total_actions == 1 and observation.drops == 4 and
                   observation.last_reason == :duplicate
               end)

        set_real_clock(context.clock, ~U[2026-08-08 16:00:10Z])
        send(source_owner, :flush_window)
        drain_vertical_once(context.buffer)

        assert eventually(fn ->
                 :sys.get_state(source_owner).committed_cursor == second_frame["time_us"]
               end)
      end)

    rows =
      Repo.all(
        from event in Event,
          where: event.external_id in [@first_external_id, @second_external_id],
          order_by: [asc: event.occurred_at]
      )

    assert Enum.map(rows, & &1.external_id) == [@first_external_id, @second_external_id]
    assert Enum.map(rows, & &1.payload["total_actions"]) == [1, 1]
    assert Enum.map(rows, & &1.payload["window_count"]) == [1, 1]
    assert Enum.map(rows, & &1.payload["window_span_seconds"]) == [4, 4]

    assert Repo.get!(FeedCheckpoint, "bluesky").cursor ==
             Integer.to_string(second_frame["time_us"])

    browser_instructions = Enum.map(rows, &Instruction.from_event/1)

    public_surface =
      inspect({rows, browser_instructions, Coordinator.current_snapshot(context.coordinator)})

    operational_surface =
      inspect({:sys.get_state(source_owner), HealthRegistry.current(context.health)})

    telemetry_surface = context |> vertical_telemetry() |> inspect()

    private_markers = [
      "did:example:synthetic-alpha",
      "synthetic.invalid",
      "synthetic-cursor-never-retained",
      "synthetic-post-key",
      "synthetic words used only to test privacy",
      "at://did:example:synthetic-alpha/app.bsky.feed.post/synthetic-post-key",
      "synthetic-content-id",
      "did:example:synthetic-identity",
      "did:example:synthetic-account",
      "cursor",
      Integer.to_string(first_frame["time_us"]),
      Integer.to_string(second_frame["time_us"])
    ]

    for marker <- private_markers do
      refute public_surface =~ marker
      refute operational_surface =~ marker
      refute telemetry_surface =~ marker
      refute captured_log =~ marker
    end
  end

  test "builds the exact bounded subscription URL and installs process limits" do
    now = ~U[2026-08-08 16:00:30Z]
    committed_cursor = DateTime.to_unix(now, :microsecond) - 10_000_000
    context = start_socket(now, committed_cursor: committed_cursor)

    assert_receive {:transport_connect, endpoint, transport_id}, 500

    assert URI.parse(endpoint).query |> URI.query_decoder() |> Enum.to_list() == [
             {"wantedCollections", "app.bsky.feed.post"},
             {"wantedCollections", "app.bsky.feed.repost"},
             {"maxMessageSizeBytes", "262144"},
             {"compress", "false"},
             {"cursor", Integer.to_string(committed_cursor - 5_000_000)}
           ]

    assert {:max_heap_size, heap_policy} = Process.info(context.socket, :max_heap_size)

    assert Map.take(heap_policy, [:size, :kill, :error_logger]) ==
             %{size: 2_000_000, kill: true, error_logger: false}

    send(context.socket, {:fake_socket, transport_id, [:connected]})

    assert eventually(fn ->
             HealthRegistry.current(context.health).bluesky.connection == :connected
           end)
  end

  test "abandons a cursor that ages past the replay horizon and records one coarse gap" do
    now = ~U[2026-08-08 16:00:30Z]
    committed_cursor = DateTime.to_unix(now, :microsecond) - 10_000_000
    context = start_socket(now, committed_cursor: committed_cursor)
    {first_id, context} = connect(context)

    set_clock(context.clock, DateTime.add(now, 51, :second))
    send(context.socket, {:fake_socket, first_id, [{:close, 1_001, "restart"}]})
    assert_receive {:transport_acknowledged_close, ^first_id, 1_001}, 500

    send(context.socket, {:connect, reconnect_token(context.socket)})
    assert_receive {:transport_connect, live_tail_endpoint, _second_id}, 500
    refute URI.parse(live_tail_endpoint).query =~ "cursor="

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).bluesky
             observation.drops == 1 and observation.last_reason == :replay
           end)
  end

  test "reduces one complete frame synchronously, deduplicates overlap, and persists only aggregates" do
    now = ~U[2026-08-08 16:00:03.500000Z]
    context = start_socket(now)
    {transport_id, context} = connect(context)
    reset_clock_count(context.clock)

    frame = complete_frame(DateTime.to_unix(now, :microsecond))
    encoded = Jason.encode!(frame)
    send(context.socket, {:fake_socket, transport_id, [{:text, encoded}]})

    assert eventually(fn ->
             HealthRegistry.current(context.health).bluesky.last_contact_at == now
           end)

    assert clock_count(context.clock) == 1

    send(context.socket, {:fake_socket, transport_id, [{:text, encoded}]})

    assert eventually(fn -> HealthRegistry.current(context.health).bluesky.drops == 1 end)
    assert HealthRegistry.current(context.health).bluesky.last_reason == :duplicate

    set_clock(context.clock, ~U[2026-08-08 16:00:07Z])
    send(context.socket, :flush_window)

    assert_receive {:buffer_submit, [event], checkpoint}, 500
    assert event.source == :bluesky
    assert event.payload["total_actions"] == 1
    assert event.payload["original_posts"] == 1
    assert checkpoint.source == "bluesky"
    assert checkpoint.cursor == Integer.to_string(frame["time_us"])

    inspected = inspect(:sys.get_state(context.socket))

    for marker <- [frame["did"], frame["commit"]["rkey"], "private words", checkpoint.cursor] do
      refute inspected =~ marker
    end
  end

  test "holds one successor through grace and accepts a later current-window frame" do
    context = start_socket(~U[2026-08-08 16:00:03.500000Z])
    {transport_id, context} = connect(context)
    first = complete_frame(DateTime.to_unix(~U[2026-08-08 16:00:03.500000Z], :microsecond))
    successor = complete_frame(DateTime.to_unix(~U[2026-08-08 16:00:05.500000Z], :microsecond))
    late_current = complete_frame(DateTime.to_unix(~U[2026-08-08 16:00:04.500000Z], :microsecond))

    send_text(context.socket, transport_id, first)
    assert eventually(fn -> :sys.get_state(context.socket).window.total_actions == 1 end)

    set_clock(context.clock, ~U[2026-08-08 16:00:05.500000Z])
    send_text(context.socket, transport_id, successor)
    assert eventually(fn -> not is_nil(:sys.get_state(context.socket).next_window) end)
    refute_receive {:buffer_submit, _events, _checkpoint}, 50

    set_clock(context.clock, ~U[2026-08-08 16:00:05.750000Z])
    send_text(context.socket, transport_id, late_current)
    assert eventually(fn -> :sys.get_state(context.socket).window.total_actions == 2 end)

    set_clock(context.clock, ~U[2026-08-08 16:00:06Z])
    send(context.socket, :flush_window)

    assert_receive {:buffer_submit, [current_event], current_checkpoint}, 500
    assert current_event.payload["total_actions"] == 2
    assert current_checkpoint.cursor == Integer.to_string(late_current["time_us"])

    set_clock(context.clock, ~U[2026-08-08 16:00:10Z])
    send(context.socket, :flush_window)

    assert_receive {:buffer_submit, [successor_event], successor_checkpoint}, 500
    assert successor_event.payload["total_actions"] == 1
    assert successor_checkpoint.cursor == Integer.to_string(successor["time_us"])
  end

  test "does not promote a successor or advance recovery when durability fails" do
    buffer = fn _events, _checkpoint -> {:error, :unavailable} end
    context = start_socket(~U[2026-08-08 16:00:03.500000Z], buffer: buffer)
    {transport_id, context} = connect(context)
    current = complete_frame(DateTime.to_unix(~U[2026-08-08 16:00:03.500000Z], :microsecond))
    successor = complete_frame(DateTime.to_unix(~U[2026-08-08 16:00:05.500000Z], :microsecond))

    send_text(context.socket, transport_id, current)
    assert eventually(fn -> :sys.get_state(context.socket).window.total_actions == 1 end)

    set_clock(context.clock, ~U[2026-08-08 16:00:05.500000Z])
    send_text(context.socket, transport_id, successor)
    assert eventually(fn -> not is_nil(:sys.get_state(context.socket).next_window) end)

    durable_fields = [
      :window,
      :window_cursor,
      :next_window,
      :next_window_cursor,
      :recovery,
      :next_recovery,
      :committed_cursor
    ]

    before_failure = context.socket |> :sys.get_state() |> Map.take(durable_fields)

    set_clock(context.clock, ~U[2026-08-08 16:00:06Z])
    send(context.socket, :flush_window)

    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             state = :sys.get_state(context.socket)

             Map.take(state, durable_fields) == before_failure and
               HealthRegistry.current(context.health).bluesky.last_reason == :persistence
           end)
  end

  test "preserves uncommitted fingerprints across reconnect replay" do
    now = ~U[2026-08-08 16:00:03Z]
    context = start_socket(now)
    {first_id, context} = connect(context)
    frame = complete_frame(DateTime.to_unix(now, :microsecond))

    send_text(context.socket, first_id, frame)
    assert eventually(fn -> :sys.get_state(context.socket).window.total_actions == 1 end)

    send(context.socket, {:fake_socket, first_id, [{:close, 1_001, "restart"}]})
    assert_receive {:transport_acknowledged_close, ^first_id, 1_001}, 500
    token = reconnect_token(context.socket)
    send(context.socket, {:connect, token})
    assert_receive {:transport_connect, _endpoint, second_id}, 500
    send(context.socket, {:fake_socket, second_id, [:connected]})

    send_text(context.socket, second_id, frame)

    assert eventually(fn ->
             state = :sys.get_state(context.socket)

             state.window.total_actions == 1 and
               HealthRegistry.current(context.health).bluesky.last_reason == :duplicate
           end)
  end

  test "sanitizes a future checkpoint and adopts the next durable live cursor" do
    now = ~U[2026-08-08 16:00:03Z]
    future_cursor = DateTime.to_unix(now, :microsecond) + 1
    assert_sanitized_checkpoint_recovery(now, future_cursor)
  end

  test "sanitizes an out-of-horizon checkpoint and adopts the next durable live cursor" do
    now = ~U[2026-08-08 16:00:03Z]
    stale_cursor = DateTime.to_unix(now, :microsecond) - 60_000_001
    assert_sanitized_checkpoint_recovery(now, stale_cursor)
  end

  test "reducer-invalid identities do not consume overlap capacity" do
    now = ~U[2026-08-08 16:00:03Z]
    context = start_socket(now)
    {transport_id, context} = connect(context)
    cursor = DateTime.to_unix(now, :microsecond)
    invalid = put_in(complete_frame(cursor), ["commit", "record"], "private-invalid-record")

    send_text(context.socket, transport_id, invalid)
    assert eventually(fn -> HealthRegistry.current(context.health).bluesky.drops == 1 end)
    assert :sys.get_state(context.socket).recovery.fingerprints == MapSet.new()

    send_text(context.socket, transport_id, complete_frame(cursor))
    assert eventually(fn -> :sys.get_state(context.socket).window.total_actions == 1 end)
  end

  test "marks the targeted aggregate truncated when fingerprint capacity drops an event" do
    now = ~U[2026-08-08 16:00:03Z]
    context = start_socket(now)
    {transport_id, context} = connect(context)

    :sys.replace_state(context.socket, fn state ->
      fingerprints =
        MapSet.new(1..4_096, fn index ->
          :crypto.hash(:sha256, Integer.to_string(index))
        end)

      %{state | recovery: %{state.recovery | fingerprints: fingerprints}}
    end)

    send_text(context.socket, transport_id, complete_frame(DateTime.to_unix(now, :microsecond)))

    assert eventually(fn ->
             state = :sys.get_state(context.socket)
             state.window.total_actions == 0 and state.window.truncated
           end)

    assert HealthRegistry.current(context.health).bluesky.last_reason == :capacity
  end

  test "drops malformed, account, identity, and binary records without crashing a sibling" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    sibling = start_supervised!({Task, fn -> Process.sleep(:infinity) end})
    {transport_id, context} = connect(context)

    frames = [
      {:text, "{malformed"},
      {:text, Jason.encode!(%{"kind" => "identity"})},
      {:text, Jason.encode!(%{"kind" => "account"})},
      {:binary, "private-binary"}
    ]

    Enum.each(frames, fn frame ->
      send(context.socket, {:fake_socket, transport_id, [frame]})
    end)

    assert eventually(fn -> HealthRegistry.current(context.health).bluesky.drops == 4 end)
    assert Process.alive?(context.socket)
    assert Process.alive?(sibling)
  end

  test "echoes ping, acknowledges close, closes old state, and ignores stale messages" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {first_id, context} = connect(context)

    send(context.socket, {:fake_socket, first_id, [{:ping, "pulse"}]})
    assert_receive {:transport_sent, ^first_id, {:pong, "pulse"}}, 500

    send(context.socket, {:fake_socket, first_id, [{:close, 1_001, "restart"}]})
    assert_receive {:transport_acknowledged_close, ^first_id, 1_001}, 500
    assert_receive {:timer_scheduled, {:connect, reconnect_token}, delay}, 500
    assert delay in 1_000..300_000

    send(context.socket, {:connect, reconnect_token})
    assert_receive {:transport_connect, _endpoint, second_id}, 500
    assert second_id != first_id

    stale_frame = complete_frame(DateTime.to_unix(~U[2026-08-08 16:00:03Z], :microsecond))
    send(context.socket, {:fake_socket, first_id, [{:text, Jason.encode!(stale_frame)}]})
    refute_receive {:buffer_submit, _events, _checkpoint}, 100
    assert Process.alive?(context.socket)
  end

  test "disconnects before application work on frame, transport, and mailbox limits" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)

    send(context.socket, {:fake_error, transport_id, :frame_limit})
    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).bluesky
             observation.connection == :disconnected and observation.last_reason == :backpressure
           end)

    send(context.socket, {:connect, reconnect_token(context.socket)})
    assert_receive {:transport_connect, _endpoint, next_id}, 500
    send(context.socket, {:fake_socket, next_id, [:connected]})

    :ok = :sys.suspend(context.socket)
    monitor = Process.monitor(context.socket)
    Enum.each(1..102, fn _index -> send(context.socket, :mailbox_pressure) end)
    :ok = :sys.resume(context.socket)

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 500

    assert eventually(fn ->
             HealthRegistry.current(context.health).bluesky.last_reason == :mailbox
           end)

    refute Process.alive?(context.socket)
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
         topic: "loom:bluesky-vertical:#{System.unique_integer([:positive, :monotonic])}"}
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
        {BlueskySocket,
         name: nil,
         url: WebSocketFixtureServer.endpoint(server),
         committed_cursor: nil,
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

  defp attach_vertical_telemetry(test_process) do
    handler_id = "bluesky-vertical-#{System.unique_integer([:positive, :monotonic])}"

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

    Repo.delete_all(from checkpoint in FeedCheckpoint, where: checkpoint.source == "bluesky")
  end

  defp assert_subscription_query(query, replay_cursor) do
    expected = [
      {"wantedCollections", "app.bsky.feed.post"},
      {"wantedCollections", "app.bsky.feed.repost"},
      {"maxMessageSizeBytes", "262144"},
      {"compress", "false"}
    ]

    expected =
      if is_integer(replay_cursor),
        do: expected ++ [{"cursor", Integer.to_string(replay_cursor)}],
        else: expected

    assert query |> URI.query_decoder() |> Enum.to_list() == expected
  end

  defp push_frames(connection, frames) do
    barrier = "fixture-barrier-#{System.unique_integer([:positive, :monotonic])}"
    encoded = Enum.map(frames, &{:text, Jason.encode!(&1)})
    send(connection, {:push_many, encoded ++ [{:ping, barrier}]})
    assert_receive {:fixture_control, :pong, ^barrier}, 1_000
  end

  defp drain_vertical_once(buffer) do
    assert_receive {:vertical_buffer_timer, ^buffer, {:drain, _token} = message, 250}, 1_000
    send(buffer, message)
    assert eventually(fn -> Buffer.depth(buffer) == 0 end)
  end

  defp read_frames do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp at(frame, occurred_at) do
    Map.put(frame, "time_us", DateTime.to_unix(occurred_at, :microsecond))
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
        {BlueskySocket,
         [
           name: nil,
           url: "wss://jetstream.example.invalid/subscribe?token=discarded",
           committed_cursor: Keyword.get(options, :committed_cursor),
           transport: FakeWebSocketTransport,
           transport_options: [owner: test_process],
           buffer: buffer,
           health_registry: health,
           clock: clock_fun(clock),
           random: fn -> 0.5 end,
           timer: timer
         ]}
      )

    %{socket: socket, health: health, clock: clock}
  end

  defp connect(context) do
    assert_receive {:transport_connect, _endpoint, transport_id}, 500
    send(context.socket, {:fake_socket, transport_id, [:connected]})

    assert eventually(fn ->
             HealthRegistry.current(context.health).bluesky.connection == :connected
           end)

    {transport_id, context}
  end

  defp complete_frame(time_us) do
    %{
      "time_us" => time_us,
      "kind" => "commit",
      "did" => "did:example:private-alpha",
      "commit" => %{
        "collection" => "app.bsky.feed.post",
        "operation" => "create",
        "rkey" => "private-record-key",
        "record" => %{"text" => "private words"}
      }
    }
  end

  defp send_text(socket, transport_id, frame) do
    send(socket, {:fake_socket, transport_id, [{:text, Jason.encode!(frame)}]})
  end

  defp assert_sanitized_checkpoint_recovery(now, poisoned_cursor) do
    context = start_socket(now, committed_cursor: poisoned_cursor)

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).bluesky
             observation.drops == 1 and observation.last_reason == :replay
           end)

    assert_receive {:transport_connect, first_endpoint, first_id}, 500
    refute URI.parse(first_endpoint).query =~ "cursor="
    send(context.socket, {:fake_socket, first_id, [:connected]})

    frame = complete_frame(DateTime.to_unix(now, :microsecond))
    send_text(context.socket, first_id, frame)
    assert eventually(fn -> :sys.get_state(context.socket).window.total_actions == 1 end)

    set_clock(context.clock, ~U[2026-08-08 16:00:07Z])
    send(context.socket, :flush_window)
    assert_receive {:buffer_submit, [_event], checkpoint}, 500
    assert checkpoint.cursor == Integer.to_string(frame["time_us"])

    send(context.socket, {:fake_socket, first_id, [{:close, 1_001, "restart"}]})
    assert_receive {:transport_acknowledged_close, ^first_id, 1_001}, 500
    token = reconnect_token(context.socket)
    send(context.socket, {:connect, token})
    assert_receive {:transport_connect, replay_endpoint, _second_id}, 500

    expected_replay = Integer.to_string(frame["time_us"] - 5_000_000)

    assert URI.parse(replay_endpoint).query
           |> URI.query_decoder()
           |> Enum.member?({"cursor", expected_replay})
  end

  defp clock_fun(clock) do
    fn ->
      Agent.get_and_update(clock, fn state -> {state.now, %{state | count: state.count + 1}} end)
    end
  end

  defp set_clock(clock, now), do: Agent.update(clock, &%{&1 | now: now})
  defp reset_clock_count(clock), do: Agent.update(clock, &%{&1 | count: 0})
  defp clock_count(clock), do: Agent.get(clock, & &1.count)

  defp reconnect_token(socket) do
    receive do
      {:timer_scheduled, {:connect, token}, _delay} -> token
      _other -> reconnect_token(socket)
    after
      500 -> flunk("expected reconnect timer for #{inspect(socket)}")
    end
  end

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
