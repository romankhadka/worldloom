defmodule Worldloom.Signals.BalanceMonitorTest do
  use ExUnit.Case

  alias Worldloom.Loom.Event
  alias Worldloom.Loom.LiveSnapshot
  alias Worldloom.Signals.BalanceMonitor

  @quota_sources [:wikimedia, :bluesky, :ripe_ris, :solana, :drand]
  @source_kinds %{
    wikimedia: "wikimedia",
    bluesky: "public_activity",
    ripe_ris: "route_change",
    solana: "slot",
    drand: "randomness"
  }
  @start ~U[2026-08-08 12:00:00.000000Z]

  test "reports every eligible interval when every source genuinely occurs" do
    {monitor, clock, measurements} = start_monitor(all_live_health())

    for second <- 0..299 do
      set_clock(clock, second)

      if rem(second, 10) == 0 do
        send(monitor, {:loom_snapshot, snapshot(events_for_sources(@quota_sources, second))})
      end

      send(monitor, :balance_boundary)
      :sys.get_state(monitor)
    end

    assert Agent.get(measurements, & &1) ==
             Map.new(@quota_sources, &{&1, %{observed: 300, eligible: 300}})
  end

  test "a missing occurrence fails every affected rolling interval" do
    health = health_projection(%{wikimedia: :live})
    {monitor, clock, measurements} = start_monitor(health)

    for second <- 0..299 do
      set_clock(clock, second)

      if rem(second, 10) == 0 and second != 100 do
        send(monitor, {:loom_snapshot, snapshot([event(:wikimedia, second)])})
      end

      send(monitor, :balance_boundary)
      :sys.get_state(monitor)
    end

    assert Agent.get(measurements, & &1).wikimedia == %{observed: 290, eligible: 300}
  end

  test "only live sources enter an interval denominator" do
    health =
      health_projection(%{
        wikimedia: :live,
        bluesky: :disabled,
        ripe_ris: :disconnected,
        drand: :quiet
      })

    {monitor, _clock, measurements} = start_monitor(health)
    send(monitor, {:loom_snapshot, snapshot(events_for_sources(@quota_sources, 0))})
    send(monitor, :balance_boundary)
    :sys.get_state(monitor)

    assert Agent.get(measurements, & &1) == %{
             wikimedia: %{observed: 1, eligible: 1},
             bluesky: %{observed: 0, eligible: 0},
             ripe_ris: %{observed: 0, eligible: 0},
             solana: %{observed: 0, eligible: 0},
             drand: %{observed: 0, eligible: 0}
           }
  end

  test "health transitions change eligibility only at the observed boundary" do
    {monitor, clock, measurements} = start_monitor(health_projection(%{}))

    send(monitor, {:loom_snapshot, snapshot([event(:wikimedia, 0)])})
    send(monitor, :balance_boundary)
    :sys.get_state(monitor)

    set_clock(clock, 1)
    send(monitor, {:feed_health, health_projection(%{wikimedia: :live})})
    send(monitor, {:loom_snapshot, snapshot([event(:wikimedia, 1)])})
    send(monitor, :balance_boundary)
    :sys.get_state(monitor)

    set_clock(clock, 2)
    send(monitor, {:feed_health, health_projection(%{wikimedia: :quiet})})
    send(monitor, {:loom_snapshot, snapshot([event(:wikimedia, 2)])})
    send(monitor, :balance_boundary)
    :sys.get_state(monitor)

    set_clock(clock, 3)
    send(monitor, {:feed_health, health_projection(%{wikimedia: :live})})
    send(monitor, :balance_boundary)
    state = :sys.get_state(monitor)

    assert state.eligibility[unix_second(0)] == MapSet.new()
    assert state.eligibility[unix_second(1)] == MapSet.new([:wikimedia])
    assert state.eligibility[unix_second(2)] == MapSet.new()
    assert state.eligibility[unix_second(3)] == MapSet.new([:wikimedia])
    assert Agent.get(measurements, & &1).wikimedia == %{observed: 2, eligible: 2}
  end

  test "health projection storage is fixed, state-only, and fail-safe" do
    initial_health = %{
      "bluesky" => %{state: :live},
      wikimedia: %{state: :live, observed_at: @start, private_reason: :ignored}
    }

    {monitor, clock, _measurements} = start_monitor(initial_health)

    send(monitor, :balance_boundary)
    initial_state = :sys.get_state(monitor)

    assert initial_state.live_sources == MapSet.new([:wikimedia])

    set_clock(clock, 1)

    send(
      monitor,
      {:feed_health, %{wikimedia: %{state: :live, observed_at: DateTime.add(@start, 1, :second)}}}
    )

    send(monitor, :balance_boundary)
    timestamp_only_state = :sys.get_state(monitor)

    assert timestamp_only_state.live_sources == initial_state.live_sources

    set_clock(clock, 2)
    send(monitor, {:feed_health, %{wikimedia: %{state: "live"}, bluesky: nil}})
    send(monitor, :balance_boundary)
    malformed_state = :sys.get_state(monitor)

    assert malformed_state.live_sources == MapSet.new()

    set_clock(clock, 3)
    send(monitor, {:feed_health, :malformed})
    send(monitor, :balance_boundary)
    non_map_state = :sys.get_state(monitor)

    assert non_map_state.live_sources == MapSet.new()
  end

  test "accepts only the five exact public source-kind pairs" do
    {monitor, clock, _measurements} = start_monitor(all_live_health())

    excluded = [
      event(:wikimedia, 1, "weather"),
      event(:bluesky, 1, "route_change"),
      event(:ripe_ris, 1, "slot"),
      event(:solana, 1, "randomness"),
      event(:drand, 1, "public_activity"),
      event(:usgs, 1, "earthquake"),
      event(:open_meteo, 1, "weather"),
      event(:visitor, 1, "tug")
    ]

    set_clock(clock, 1)

    send(
      monitor,
      {:loom_snapshot, snapshot(events_for_sources(@quota_sources, 0) ++ excluded)}
    )

    state = :sys.get_state(monitor)

    assert state.occurrences == %{unix_second(0) => MapSet.new(@quota_sources)}
    refute Map.has_key?(state.occurrences, unix_second(1))
  end

  test "retains at most 310 occurrence and eligibility seconds" do
    {monitor, clock, _measurements} = start_monitor(all_live_health())

    for second <- 0..399 do
      set_clock(clock, second)
      send(monitor, {:loom_snapshot, snapshot([event(:wikimedia, second)])})
      send(monitor, :balance_boundary)
      :sys.get_state(monitor)
    end

    state = :sys.get_state(monitor)
    retained_seconds = MapSet.new(unix_second(90)..unix_second(399))

    assert Map.keys(state.occurrences) |> MapSet.new() == retained_seconds
    assert Map.keys(state.eligibility) |> MapSet.new() == retained_seconds
    assert map_size(state.occurrences) == 310
    assert map_size(state.eligibility) == 310
  end

  test "keeps exact retention boundaries and rejects expired or future occurrences" do
    {monitor, clock, _measurements} = start_monitor(all_live_health())
    set_clock(clock, 400)

    boundary_events = [
      event(:wikimedia, 90),
      event(:wikimedia, 91),
      event(:wikimedia, 400),
      event(:wikimedia, 401)
    ]

    send(monitor, {:loom_snapshot, snapshot(boundary_events)})
    first_state = :sys.get_state(monitor)
    send(monitor, {:loom_snapshot, snapshot(boundary_events)})
    repeated_state = :sys.get_state(monitor)

    assert first_state.occurrences == %{
             unix_second(91) => MapSet.new([:wikimedia]),
             unix_second(400) => MapSet.new([:wikimedia])
           }

    assert repeated_state.occurrences == first_state.occurrences
  end

  test "a late genuine occurrence repairs every still-retained affected interval" do
    {monitor, clock, measurements} = start_monitor(health_projection(%{wikimedia: :live}))

    for second <- 0..19 do
      set_clock(clock, second)
      send(monitor, :balance_boundary)
      :sys.get_state(monitor)
    end

    assert Agent.get(measurements, & &1).wikimedia == %{observed: 0, eligible: 20}

    send(monitor, {:loom_snapshot, snapshot([event(:wikimedia, 10)])})
    set_clock(clock, 20)
    send(monitor, :balance_boundary)
    repaired_state = :sys.get_state(monitor)

    assert repaired_state.occurrences[unix_second(10)] == MapSet.new([:wikimedia])
    assert Agent.get(measurements, & &1).wikimedia == %{observed: 10, eligible: 21}
  end

  test "aligns scheduling to the next whole-second boundary" do
    for {time, expected_delay} <- [
          {@start, 1_000},
          {%{@start | microsecond: {250_000, 6}}, 750},
          {%{@start | microsecond: {999_000, 6}}, 1}
        ] do
      owner = self()

      {:ok, monitor} =
        BalanceMonitor.start_link(
          name: nil,
          subscriber: fn _topic -> :ok end,
          snapshot_loader: fn -> snapshot([]) end,
          health_loader: fn -> health_projection(%{}) end,
          clock: fn -> time end,
          timer: fn _process, _message, delay ->
            send(owner, {:scheduled, delay})
            make_ref()
          end,
          emitter: fn _source, _observed, _eligible -> :ok end
        )

      assert_receive {:scheduled, ^expected_delay}, 500
      GenServer.stop(monitor)
    end
  end

  test "subscribes before seeding from authoritative snapshot and current health" do
    owner = self()
    clock = start_supervised!({Agent, fn -> @start end}, id: make_ref())
    measurements = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    subscriber = fn topic ->
      send(owner, {:subscribed, topic})
      :ok
    end

    {:ok, monitor} =
      BalanceMonitor.start_link(
        name: nil,
        subscriber: subscriber,
        snapshot_loader: fn ->
          send(owner, :loaded_snapshot)
          snapshot([event(:wikimedia, 0)])
        end,
        health_loader: fn ->
          send(owner, :loaded_health)
          health_projection(%{wikimedia: :live})
        end,
        clock: fn -> Agent.get(clock, & &1) end,
        timer: fn _process, _message, _delay -> make_ref() end,
        emitter: measurement_emitter(measurements)
      )

    bootstrap_trace =
      for _step <- 1..4 do
        receive do
          message -> message
        after
          500 -> flunk("balance monitor bootstrap did not complete")
        end
      end

    assert bootstrap_trace == [
             {:subscribed, "loom:events"},
             {:subscribed, "signals:health"},
             :loaded_health,
             :loaded_snapshot
           ]

    send(monitor, :balance_boundary)
    :sys.get_state(monitor)

    assert Agent.get(measurements, & &1).wikimedia == %{observed: 1, eligible: 1}
  end

  test "emits integer counts with only the fixed source atom as metadata" do
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:worldloom, :signals, :balance],
        fn event_name, measurements, metadata, _config ->
          send(owner, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {monitor, _clock, _measurements} =
      start_monitor(health_projection(%{wikimedia: :live}), emitter: nil)

    send(monitor, {:loom_snapshot, snapshot([event(:wikimedia, 0)])})
    send(monitor, :balance_boundary)
    :sys.get_state(monitor)

    reports =
      for _source <- @quota_sources do
        assert_receive {:telemetry, [:worldloom, :signals, :balance], measurements, metadata}

        assert Map.keys(measurements) |> Enum.sort() == [:eligible, :observed]
        assert is_integer(measurements.observed)
        assert is_integer(measurements.eligible)
        assert %{source: source} = metadata
        assert metadata == %{source: source}
        {source, measurements}
      end

    assert reports |> Enum.map(&elem(&1, 0)) |> MapSet.new() == MapSet.new(@quota_sources)
  end

  test "one-for-one supervision restarts the monitor without restarting a sibling" do
    monitor_options = [
      name: nil,
      subscriber: fn _topic -> :ok end,
      snapshot_loader: fn -> snapshot([]) end,
      health_loader: fn -> health_projection(%{}) end,
      clock: fn -> @start end,
      timer: fn _process, _message, _delay -> make_ref() end,
      emitter: fn _source, _observed, _eligible -> :ok end
    ]

    children = [
      Supervisor.child_spec({Agent, fn -> :sibling end}, id: :sibling),
      Supervisor.child_spec({BalanceMonitor, monitor_options}, id: :balance_monitor)
    ]

    supervisor =
      start_supervised!(%{
        id: {:isolated_balance_supervisor, make_ref()},
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
      })

    sibling = child_pid(supervisor, :sibling)
    monitor = child_pid(supervisor, :balance_monitor)

    monitor_ref = Process.monitor(monitor)
    Process.exit(monitor, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^monitor, :killed}, 500

    restarted_monitor = await_restarted_child(supervisor, :balance_monitor, monitor)

    assert is_pid(restarted_monitor)
    assert Process.alive?(restarted_monitor)
    assert child_pid(supervisor, :sibling) == sibling
  end

  defp start_monitor(health, options \\ []) do
    clock = start_supervised!({Agent, fn -> @start end}, id: make_ref())
    measurements = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    monitor_options = [
      name: nil,
      subscriber: fn _topic -> :ok end,
      snapshot_loader: fn -> snapshot([]) end,
      health_loader: fn -> health end,
      clock: fn -> Agent.get(clock, & &1) end,
      timer: fn _process, _message, _delay -> make_ref() end,
      emitter: measurement_emitter(measurements)
    ]

    monitor_options =
      case Keyword.fetch(options, :emitter) do
        {:ok, nil} -> Keyword.delete(monitor_options, :emitter)
        {:ok, emitter} -> Keyword.put(monitor_options, :emitter, emitter)
        :error -> monitor_options
      end

    {:ok, monitor} = BalanceMonitor.start_link(monitor_options)
    {monitor, clock, measurements}
  end

  defp measurement_emitter(measurements) do
    fn source, observed, eligible ->
      Agent.update(measurements, &Map.put(&1, source, %{observed: observed, eligible: eligible}))
    end
  end

  defp set_clock(clock, seconds) do
    Agent.update(clock, fn _current -> DateTime.add(@start, seconds, :second) end)
  end

  defp all_live_health do
    Map.new(@quota_sources, &{&1, %{state: :live, observed_at: @start}})
  end

  defp health_projection(states) do
    Map.new(states, fn {source, state} ->
      {source, %{state: state, observed_at: @start}}
    end)
  end

  defp events_for_sources(sources, second) do
    Enum.map(sources, &event(&1, second))
  end

  defp event(source, second, kind \\ nil) do
    source_string = Atom.to_string(source)

    %Event{
      source: source_string,
      kind: kind || Map.get(@source_kinds, source),
      occurred_at: DateTime.add(@start, second, :second)
    }
  end

  defp snapshot(events) do
    %LiveSnapshot{
      window_end: @start,
      commit_watermark: 0,
      display_events: events,
      memory_events: [],
      ambient: nil
    }
  end

  defp unix_second(offset), do: DateTime.to_unix(@start, :second) + offset

  defp child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} -> pid
      _other -> nil
    end)
  end

  defp await_restarted_child(supervisor, child_id, previous, attempts \\ 50)

  defp await_restarted_child(_supervisor, _child_id, _previous, 0), do: nil

  defp await_restarted_child(supervisor, child_id, previous, attempts) do
    case child_pid(supervisor, child_id) do
      monitor when is_pid(monitor) and monitor != previous ->
        monitor

      _not_restarted ->
        receive do
        after
          10 -> await_restarted_child(supervisor, child_id, previous, attempts - 1)
        end
    end
  end
end
