defmodule Worldloom.Signals.HealthRegistryTest do
  use ExUnit.Case, async: false

  alias Worldloom.Signals.HealthRegistry

  @now ~U[2026-08-08 12:00:00.000000Z]
  @uint32_max 4_294_967_295

  test "records only bounded lifecycle observations and notifies connection transitions" do
    owner = self()
    clock = start_supervised!({Agent, fn -> @now end})

    {:ok, registry} =
      HealthRegistry.start_link(
        name: nil,
        monitor: owner,
        clock: fn -> Agent.get(clock, & &1) end
      )

    assert :ok = HealthRegistry.record(registry, :bluesky, :connected)
    assert_receive :health_registry_changed

    advance_clock(clock, 1)
    assert :ok = HealthRegistry.record(registry, :bluesky, :contact)

    advance_clock(clock, 1)
    assert :ok = HealthRegistry.record(registry, :bluesky, {:activity, 12})

    advance_clock(clock, 1)
    assert :ok = HealthRegistry.record(registry, :bluesky, {:drop, :oversized})
    assert :ok = HealthRegistry.record(registry, :bluesky, {:merge, 3})
    assert :ok = HealthRegistry.record(registry, :bluesky, {:recovery, 2})
    assert :ok = HealthRegistry.record(registry, :bluesky, {:retry, 4})

    assert :ok = HealthRegistry.record(registry, :bluesky, :disconnected)
    assert_receive :health_registry_changed
    refute_receive :health_registry_changed

    assert HealthRegistry.current(registry).bluesky == %{
             connection: :disconnected,
             last_contact_at: DateTime.add(@now, 2, :second),
             last_activity_at: DateTime.add(@now, 2, :second),
             drops: 1,
             merges: 3,
             recovered_windows: 2,
             retries: 4,
             last_reason: :oversized
           }
  end

  test "saturates aggregate counters and never publishes counter-only changes" do
    {:ok, registry} =
      HealthRegistry.start_link(name: nil, monitor: self(), clock: fn -> @now end)

    assert :ok = HealthRegistry.record(registry, :ripe_ris, {:merge, @uint32_max})
    assert :ok = HealthRegistry.record(registry, :ripe_ris, {:merge, 1})
    assert :ok = HealthRegistry.record(registry, :ripe_ris, {:recovery, @uint32_max})
    assert :ok = HealthRegistry.record(registry, :ripe_ris, {:recovery, 1})
    assert :ok = HealthRegistry.record(registry, :ripe_ris, {:retry, @uint32_max})
    assert :ok = HealthRegistry.record(registry, :ripe_ris, {:retry, 1})
    assert :ok = HealthRegistry.record(registry, :ripe_ris, {:drop, :capacity})

    observation = HealthRegistry.current(registry).ripe_ris

    assert observation.merges == @uint32_max
    assert observation.recovered_windows == @uint32_max
    assert observation.retries == @uint32_max
    assert observation.drops == 1
    assert observation.last_reason == :capacity
    refute_receive :health_registry_changed
  end

  test "rejects untrusted sources and observations without creating atoms or retaining input" do
    {:ok, registry} =
      HealthRegistry.start_link(name: nil, monitor: self(), clock: fn -> @now end)

    private_markers = [
      "untrusted-source-#{System.unique_integer([:positive])}",
      "private-cursor",
      "wss://example.test/stream?cursor=private",
      "raw-frame-content",
      "203.0.113.42/32",
      "private-identity",
      "private-response-body"
    ]

    atom_count = :erlang.system_info(:atom_count)

    for invalid <- [
          {Enum.at(private_markers, 0), :connected},
          {:visitor, :connected},
          {:bluesky, {:activity, 0}},
          {:bluesky, {:merge, -1}},
          {:bluesky, {:recovery, 1.0}},
          {:bluesky, {:retry, :infinity}},
          {:bluesky, {:drop, Enum.at(private_markers, 1)}},
          {:bluesky, {:disconnected, Enum.at(private_markers, 2)}},
          {:bluesky, {:frame, Enum.at(private_markers, 3)}},
          {:bluesky, %{prefix: Enum.at(private_markers, 4)}},
          {:bluesky, {:identity, Enum.at(private_markers, 5)}},
          {:bluesky, {:error, Enum.at(private_markers, 6)}}
        ] do
      {source, observation} = invalid

      assert HealthRegistry.record(registry, source, observation) ==
               {:error, :invalid_observation}
    end

    assert :erlang.system_info(:atom_count) == atom_count

    inspected = inspect(HealthRegistry.current(registry))
    Enum.each(private_markers, &refute(inspected =~ &1))
    refute_receive :health_registry_changed
  end

  test "initializes every approved source to a fixed empty observation" do
    {:ok, registry} = HealthRegistry.start_link(name: nil, clock: fn -> @now end)

    snapshot = HealthRegistry.current(registry)

    assert Map.keys(snapshot) |> Enum.sort() ==
             Enum.sort([:wikimedia, :bluesky, :ripe_ris, :solana, :drand, :usgs, :open_meteo])

    assert Enum.uniq(Map.values(snapshot)) == [
             %{
               connection: :disconnected,
               last_contact_at: nil,
               last_activity_at: nil,
               drops: 0,
               merges: 0,
               recovered_windows: 0,
               retries: 0,
               last_reason: nil
             }
           ]
  end

  defp advance_clock(clock, seconds) do
    Agent.update(clock, &DateTime.add(&1, seconds, :second))
  end
end
