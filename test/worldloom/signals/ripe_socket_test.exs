defmodule Worldloom.Signals.RipeSocketTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.RipeSocket
  alias Worldloom.TestSupport.FakeWebSocketTransport

  @fixture "test/support/fixtures/feeds/ripe_frames.json"

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

  test "authorizes only collectors in the negotiated intersection" do
    context = start_socket(~U[2026-08-08 16:00:03Z])
    {transport_id, context} = connect(context)
    assert_receive {:transport_sent, ^transport_id, {:text, _request}}, 500
    send_text(context.socket, transport_id, %{"type" => "ris_rrc_list", "data" => ["rrc00"]})
    assert_receive {:transport_sent, ^transport_id, {:text, _subscription}}, 500
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
    assert_receive {:transport_sent, ^transport_id, {:text, _subscription}}, 500
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
