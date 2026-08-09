defmodule Worldloom.Signals.SolanaSocketTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.SolanaSocket
  alias Worldloom.TestSupport.FakeWebSocketTransport

  @fixture "test/support/fixtures/feeds/solana_slot_frames.json"

  test "sends the exact parameterless subscription and accepts only its exact acknowledgement" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)

    assert_receive {:transport_sent, ^transport_id, {:text, request}}, 500

    assert Jason.decode!(request) == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "method" => "slotSubscribe"
           }

    refute Map.has_key?(Jason.decode!(request), "params")
    send_text(context.socket, transport_id, acknowledgement(8_765_432_109))

    assert eventually(fn -> :sys.get_state(context.socket).subscribed? end)

    assert {:max_heap_size, heap_policy} = Process.info(context.socket, :max_heap_size)

    assert Map.take(heap_policy, [:size, :kill, :error_logger]) ==
             %{size: 2_000_000, kill: true, error_logger: false}

    inspected = inspect(:sys.get_state(context.socket))
    refute inspected =~ "8765432109"
    refute inspected =~ "discarded"
  end

  test "fails a non-exact acknowledgement closed" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500

    send_text(context.socket, transport_id, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => 7,
      "provider_detail" => "private"
    })

    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).solana
             observation.connection == :disconnected and observation.last_reason == :subscription
           end)

    refute inspect(:sys.get_state(context.socket)) =~ "provider_detail"
  end

  test "reduces a complete notification with one receipt time and checkpoints its flushed slot" do
    now = ~U[2026-08-08 16:00:03.500000Z]
    context = start_socket(now)
    {transport_id, context} = connect_and_subscribe(context)
    reset_clock_count(context.clock)
    [frame | _remaining] = read_frames()

    send_text(context.socket, transport_id, frame)

    assert eventually(fn -> :sys.get_state(context.socket).window.slot_count == 1 end)

    assert eventually(fn ->
             HealthRegistry.current(context.health).solana.last_contact_at == now
           end)

    assert clock_count(context.clock) == 1

    set_clock(context.clock, ~U[2026-08-08 16:00:08Z])
    send(context.socket, :flush_window)

    assert_receive {:buffer_submit, [event], checkpoint}, 500
    assert event.source == :solana
    assert event.payload["slot_count"] == 1
    assert event.payload["first_slot"] == 101
    assert event.payload["last_slot"] == 101
    assert event.payload["gap_count"] == 0

    assert checkpoint == %{
             source: "solana",
             cursor: "101",
             etag: nil,
             last_successful_at: ~U[2026-08-08 16:00:08Z],
             metadata: %{}
           }

    inspected = inspect(:sys.get_state(context.socket))

    for marker <- [
          "synthetic-account-never-retained",
          "synthetic-transaction-never-retained",
          "discarded"
        ] do
      refute inspected =~ marker
    end
  end

  test "closes durably and retries the same notification without checkpointing it early" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect_and_subscribe(context)
    set_clock(context.clock, ~U[2026-08-08 16:00:08Z])
    reset_clock_count(context.clock)
    [frame | _remaining] = read_frames()

    send_text(context.socket, transport_id, frame)

    assert_receive {:buffer_submit, [], empty_checkpoint}, 500
    assert empty_checkpoint.cursor == "100"
    assert empty_checkpoint.last_successful_at == ~U[2026-08-08 16:00:08Z]
    assert clock_count(context.clock) == 1

    set_clock(context.clock, ~U[2026-08-08 16:00:12Z])
    send(context.socket, :flush_window)

    assert_receive {:buffer_submit, [event], checkpoint}, 500
    assert event.payload["last_slot"] == 101
    assert checkpoint.cursor == "101"
  end

  test "checkpoints the completed window rather than an accepted successor" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect_and_subscribe(context)
    [first, second | _remaining] = read_frames()

    send_text(context.socket, transport_id, first)
    assert eventually(fn -> :sys.get_state(context.socket).window.slot_count == 1 end)
    set_clock(context.clock, ~U[2026-08-08 16:00:07Z])
    send_text(context.socket, transport_id, second)
    set_clock(context.clock, ~U[2026-08-08 16:00:08Z])
    send(context.socket, :flush_window)

    assert_receive {:buffer_submit, [first_event], first_checkpoint}, 500
    assert first_event.payload["last_slot"] == 101
    assert first_checkpoint.cursor == "101"

    set_clock(context.clock, ~U[2026-08-08 16:00:12Z])
    send(context.socket, :flush_window)

    assert_receive {:buffer_submit, [second_event], second_checkpoint}, 500
    assert second_event.payload["last_slot"] == 102
    assert second_checkpoint.cursor == "102"
  end

  test "does not install a closed successor or advance its checkpoint when durability fails" do
    buffer = fn _events, _checkpoint -> {:error, :unavailable} end
    context = start_socket(~U[2026-08-08 16:00:03Z], buffer: buffer)
    {transport_id, context} = connect_and_subscribe(context)
    [frame | _remaining] = read_frames()
    send_text(context.socket, transport_id, frame)
    assert eventually(fn -> :sys.get_state(context.socket).window.slot_count == 1 end)
    prior_state = :sys.get_state(context.socket)

    set_clock(context.clock, ~U[2026-08-08 16:00:08Z])
    send(context.socket, :flush_window)

    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             state = :sys.get_state(context.socket)

             state.window == prior_state.window and state.committed_slot == 100 and
               HealthRegistry.current(context.health).solana.last_reason == :persistence
           end)
  end

  test "rejects a mismatched subscription before aggregation and exposes only a coarse reason" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect_and_subscribe(context)
    [frame | _remaining] = read_frames()
    mismatched = put_in(frame, ["params", "subscription"], 8)

    send_text(context.socket, transport_id, mismatched)

    assert_receive {:transport_closed, ^transport_id}, 500

    assert eventually(fn ->
             observation = HealthRegistry.current(context.health).solana
             observation.connection == :disconnected and observation.last_reason == :subscription
           end)

    refute_receive {:buffer_submit, _events, _checkpoint}, 50
    refute inspect(:sys.get_state(context.socket)) =~ "subscription"
  end

  test "acknowledges provider close before reconnecting" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect_and_subscribe(context)

    send(context.socket, {:fake_socket, transport_id, [{:close, 1_001, "private-reason"}]})

    assert_receive {:transport_acknowledged_close, ^transport_id, 1_001}, 500
    assert_receive {:timer_scheduled, {:connect, _token}, delay}, 500
    assert delay in 1_000..300_000
    refute inspect(:sys.get_state(context.socket)) =~ "private-reason"
  end

  test "grows backoff across repeated provider handshake failures" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {first_id, context} = connect(context)
    assert_receive {:transport_sent, ^first_id, {:text, _request}}, 500
    send_text(context.socket, first_id, %{"jsonrpc" => "2.0", "id" => 1, "result" => -1})

    assert_receive {:timer_scheduled, {:connect, first_token}, 1_000}, 500
    send(context.socket, {:connect, first_token})
    assert_receive {:transport_connect, _endpoint, second_id}, 500
    send(context.socket, {:fake_socket, second_id, [:connected]})
    assert_receive {:transport_sent, ^second_id, {:text, _request}}, 500
    send_text(context.socket, second_id, %{"jsonrpc" => "2.0", "id" => 1, "result" => -1})

    assert_receive {:timer_scheduled, {:connect, _second_token}, 2_000}, 500
  end

  test "handles control, malformed, binary, stale, and mailbox input without harming siblings" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    sibling = start_supervised!({Task, fn -> Process.sleep(:infinity) end})
    {transport_id, context} = connect_and_subscribe(context)

    send(context.socket, {:fake_socket, transport_id, [{:ping, "pulse"}]})
    assert_receive {:transport_sent, ^transport_id, {:pong, "pulse"}}, 500

    send(context.socket, {:fake_socket, transport_id, [{:text, "{malformed"}]})

    assert eventually(fn ->
             HealthRegistry.current(context.health).solana.last_reason == :malformed
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
             HealthRegistry.current(context.health).solana.last_reason == :mailbox
           end)

    refute Process.alive?(context.socket)
    assert Process.alive?(sibling)
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
        {SolanaSocket,
         name: nil,
         url: "wss://solana.example.invalid/socket?token=discarded",
         previous_slot: 100,
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
    assert endpoint == "wss://solana.example.invalid/socket?token=discarded"
    send(context.socket, {:fake_socket, transport_id, [:connected]})
    {transport_id, context}
  end

  defp connect_and_subscribe(context) do
    {transport_id, context} = connect(context)
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500
    send_text(context.socket, transport_id, acknowledgement(7))
    assert eventually(fn -> :sys.get_state(context.socket).subscribed? end)
    {transport_id, context}
  end

  defp acknowledgement(subscription_id) do
    %{"jsonrpc" => "2.0", "id" => 1, "result" => subscription_id}
  end

  defp send_text(socket, transport_id, payload) do
    send(socket, {:fake_socket, transport_id, [{:text, Jason.encode!(payload)}]})
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
