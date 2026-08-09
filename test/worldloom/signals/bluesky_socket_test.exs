defmodule Worldloom.Signals.BlueskySocketTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.BlueskySocket
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.TestSupport.FakeWebSocketTransport

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
