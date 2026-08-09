defmodule Worldloom.Signals.SupervisorTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.BlueskySocket
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.RipeSocket
  alias Worldloom.Signals.SolanaSocket
  alias Worldloom.Signals.Supervisor, as: SignalsSupervisor
  alias Worldloom.TestSupport.FakeWebSocketTransport
  alias Worldloom.TestSupport.SignalsSupervisorProbe

  test "restarts one failed feed without restarting its sibling" do
    first_name = unique_name(:first)
    second_name = unique_name(:second)

    children = [
      %{id: :first, start: {SignalsSupervisorProbe, :start_link, [{first_name, self()}]}},
      %{id: :second, start: {SignalsSupervisorProbe, :start_link, [{second_name, self()}]}}
    ]

    {:ok, supervisor} = SignalsSupervisor.start_link(name: nil, children: children)

    assert_receive {:started, first_pid}, 500
    assert_receive {:started, second_pid}, 500
    Process.exit(first_pid, :kill)
    assert_receive {:started, restarted_first_pid}, 500

    assert restarted_first_pid != first_pid
    assert Process.whereis(first_name) == restarted_first_pid
    assert Process.whereis(second_name) == second_pid
    assert Process.alive?(supervisor)
  end

  test "starts no feed children when ingestion is disabled" do
    {:ok, supervisor} =
      SignalsSupervisor.start_link(name: nil, config: [enabled: false])

    assert Supervisor.which_children(supervisor) == []
  end

  test "restarts a real source owner without restarting either sibling" do
    health =
      start_supervised!(
        {HealthRegistry, name: nil, monitor: nil, clock: fn -> ~U[2026-08-08 16:00:03Z] end}
      )

    shared = [
      name: nil,
      transport: FakeWebSocketTransport,
      transport_options: [owner: self()],
      buffer: fn _events, _checkpoint -> :ok end,
      health_registry: health,
      clock: fn -> ~U[2026-08-08 16:00:03Z] end,
      random: fn -> 0.5 end,
      timer: fn _destination, _message, _delay -> make_ref() end
    ]

    children = [
      {BlueskySocket,
       Keyword.merge(shared,
         url: "wss://bluesky.example.invalid/socket",
         committed_cursor: nil
       )},
      {RipeSocket,
       Keyword.merge(shared,
         url: "wss://ripe.example.invalid/socket",
         collectors: ["rrc00"]
       )},
      {SolanaSocket,
       Keyword.merge(shared,
         url: "wss://solana.example.invalid/socket",
         previous_slot: nil
       )}
    ]

    {:ok, supervisor} = SignalsSupervisor.start_link(name: nil, children: children)

    for _source <- children do
      assert_receive {:transport_connect, _endpoint, _transport_id}, 500
    end

    bluesky = child_pid(supervisor, BlueskySocket)
    ripe = child_pid(supervisor, RipeSocket)
    solana = child_pid(supervisor, SolanaSocket)

    Process.exit(bluesky, :kill)
    assert_receive {:transport_connect, "wss://bluesky.example.invalid/socket" <> _, _id}, 500

    assert child_pid(supervisor, BlueskySocket) != bluesky
    assert child_pid(supervisor, RipeSocket) == ripe
    assert child_pid(supervisor, SolanaSocket) == solana
  end

  test "configured ingestion does not start qualified WebSocket owners" do
    config = [
      enabled: true,
      wikimedia_url: "https://example.invalid/wikimedia",
      usgs_url: "https://example.invalid/usgs",
      open_meteo_url: "https://example.invalid/weather",
      earthquake_interval_ms: 60_000,
      weather_interval_ms: 600_000
    ]

    assert {:ok, {_flags, child_specs}} = SignalsSupervisor.init(config: config)
    configured_ids = Enum.map(child_specs, & &1.id)

    refute BlueskySocket in configured_ids
    refute RipeSocket in configured_ids
    refute SolanaSocket in configured_ids
  end

  defp child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} -> pid
      _child -> nil
    end)
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
