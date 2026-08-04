defmodule Worldloom.Signals.HealthMonitorTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.HealthMonitor

  @now ~U[2026-08-03 12:30:00.000000Z]

  test "caches safe health, broadcasts only changes, and recovers missing feeds" do
    test_process = self()
    checkpoints = start_supervised!({Agent, fn -> [] end})

    loader = fn -> Agent.get(checkpoints, & &1) end
    broadcaster = fn health -> send(test_process, {:broadcast, health}) end

    timer = fn process, message, delay ->
      send(test_process, {:timer, process, message, delay})
      make_ref()
    end

    {:ok, monitor} =
      HealthMonitor.start_link(
        name: nil,
        loader: loader,
        broadcaster: broadcaster,
        clock: fn -> @now end,
        timer: timer
      )

    assert_receive {:broadcast, initial_health}, 500
    assert initial_health.open_meteo.state == :stale
    assert HealthMonitor.current(monitor) == initial_health
    assert_receive {:timer, ^monitor, :refresh, 15_000}, 500

    send(monitor, :refresh)
    refute_receive {:broadcast, _unchanged}, 100

    Agent.update(checkpoints, fn _checkpoints ->
      [
        %{
          source: "open_meteo",
          last_successful_at: @now,
          metadata: %{},
          cursor: nil,
          etag: nil
        }
      ]
    end)

    send(monitor, :refresh)
    assert_receive {:broadcast, recovered_health}, 500
    assert recovered_health.open_meteo == %{state: :live, observed_at: @now}
    assert HealthMonitor.current(monitor) == recovered_health
  end

  test "emits telemetry for every projection" do
    test_process = self()
    handler_id = "health-monitor-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:worldloom, :signals, :health],
      fn event, measurements, metadata, _config ->
        send(test_process, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _monitor} =
      HealthMonitor.start_link(
        name: nil,
        loader: fn -> [] end,
        broadcaster: fn _health -> :ok end,
        clock: fn -> @now end,
        timer: fn _process, _message, _delay -> make_ref() end
      )

    assert_receive {:telemetry, [:worldloom, :signals, :health], measurements, metadata}, 500
    assert is_integer(measurements.observed_at)
    assert metadata.health.wikimedia.state == :quiet
  end
end
