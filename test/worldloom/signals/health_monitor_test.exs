defmodule Worldloom.Signals.HealthMonitorTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.HealthMonitor

  @now ~U[2026-08-03 12:30:00.000000Z]

  test "caches safe health, broadcasts only changes, and refreshes transitions immediately" do
    test_process = self()

    observations =
      start_supervised!({Agent, fn -> empty_observations() end}, id: :observations)

    observation_loader = fn -> Agent.get(observations, & &1) end
    broadcaster = fn health -> send(test_process, {:broadcast, health}) end

    timer = fn process, message, delay ->
      send(test_process, {:timer, process, message, delay})
      make_ref()
    end

    {:ok, monitor} =
      HealthMonitor.start_link(
        name: nil,
        observation_loader: observation_loader,
        broadcaster: broadcaster,
        clock: fn -> @now end,
        timer: timer
      )

    assert_receive {:broadcast, initial_health}, 500
    assert initial_health.wikimedia.state == :disconnected
    assert initial_health.open_meteo.state == :stale
    assert HealthMonitor.current(monitor) == initial_health
    assert_receive {:timer, ^monitor, :refresh, 15_000}, 500

    send(monitor, :refresh)
    refute_receive {:broadcast, _unchanged}, 100
    assert_receive {:timer, ^monitor, :refresh, 15_000}, 500

    Agent.update(observations, fn snapshot ->
      put_in(snapshot, [:wikimedia], %{
        connection: :connected,
        last_contact_at: @now,
        last_activity_at: @now,
        drops: 7,
        merges: 3,
        recovered_windows: 2,
        retries: 1,
        last_reason: :oversized
      })
    end)

    send(monitor, :health_registry_changed)
    assert_receive {:broadcast, recovered_health}, 500
    assert recovered_health.wikimedia == %{state: :live, observed_at: @now}
    assert HealthMonitor.current(monitor) == recovered_health
    refute_receive {:timer, ^monitor, :refresh, 15_000}, 100

    Agent.update(observations, fn snapshot ->
      put_in(snapshot, [:wikimedia, :connection], :disconnected)
    end)

    send(monitor, :health_registry_changed)
    assert_receive {:broadcast, disconnected_health}, 500
    assert disconnected_health.wikimedia == %{state: :disconnected, observed_at: @now}
    refute_receive {:timer, ^monitor, :refresh, 15_000}, 100
  end

  test "projects every source from sanitized observations rather than checkpoint liveness" do
    test_process = self()

    observations =
      empty_observations()
      |> put_in([:drand, :last_activity_at], DateTime.add(@now, -12, :second))
      |> put_in([:drand, :last_contact_at], DateTime.add(@now, -12, :second))
      |> put_in([:usgs, :last_contact_at], @now)
      |> put_in([:open_meteo, :last_contact_at], DateTime.add(@now, -1_801, :second))

    {:ok, monitor} =
      HealthMonitor.start_link(
        name: nil,
        observation_loader: fn -> observations end,
        broadcaster: fn health -> send(test_process, {:broadcast, health}) end,
        clock: fn -> @now end,
        timer: fn _process, _message, _delay -> make_ref() end
      )

    assert_receive {:broadcast, health}, 500
    assert health.drand == %{state: :live, observed_at: DateTime.add(@now, -12, :second)}
    assert health.usgs == %{state: :live, observed_at: @now}

    assert health.open_meteo == %{
             state: :stale,
             observed_at: DateTime.add(@now, -1_801, :second)
           }

    assert HealthMonitor.current(monitor) == health
  end

  test "emits only public health telemetry for every projection" do
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

    observations =
      empty_observations()
      |> put_in([:bluesky, :last_reason], :oversized)
      |> put_in([:bluesky, :drops], 42)

    {:ok, _monitor} =
      HealthMonitor.start_link(
        name: nil,
        observation_loader: fn -> observations end,
        broadcaster: fn _health -> :ok end,
        clock: fn -> @now end,
        timer: fn _process, _message, _delay -> make_ref() end
      )

    assert_receive {:telemetry, [:worldloom, :signals, :health], measurements, metadata}, 500
    assert is_integer(measurements.observed_at)
    assert metadata.health.wikimedia.state == :disconnected
    refute inspect(metadata) =~ "last_reason"
    refute inspect(metadata) =~ "oversized"
    refute inspect(metadata) =~ "drops"
  end

  defp empty_observations do
    Map.new(
      [:wikimedia, :bluesky, :ripe_ris, :solana, :drand, :usgs, :open_meteo],
      fn source ->
        {source,
         %{
           connection: :disconnected,
           last_contact_at: nil,
           last_activity_at: nil,
           drops: 0,
           merges: 0,
           recovered_windows: 0,
           retries: 0,
           last_reason: nil
         }}
      end
    )
  end
end
