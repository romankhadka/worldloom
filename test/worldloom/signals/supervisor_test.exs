defmodule Worldloom.Signals.SupervisorTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.BlueskySocket
  alias Worldloom.Signals.Config
  alias Worldloom.Signals.DrandWorker
  alias Worldloom.Signals.EarthquakeWorker
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.RipeSocket
  alias Worldloom.Signals.SolanaSocket
  alias Worldloom.Signals.Supervisor, as: SignalsSupervisor
  alias Worldloom.Signals.WeatherWorker
  alias Worldloom.Signals.WikimediaWorker
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
    config = %{signal_config() | enabled: false}

    {:ok, supervisor} =
      SignalsSupervisor.start_link(name: nil, config: config)

    assert Supervisor.which_children(supervisor) == []
  end

  test "builds exact children in stable order for every source flag combination" do
    source_flags = [
      {:drand_enabled, DrandWorker},
      {:bluesky_enabled, BlueskySocket},
      {:ripe_enabled, RipeSocket},
      {:solana_enabled, SolanaSocket}
    ]

    for enabled_bits <- 0..15 do
      config =
        Enum.with_index(source_flags)
        |> Enum.reduce(signal_config_with_solana_url(), fn {{setting, _child}, bit}, config ->
          Map.put(config, setting, Bitwise.band(enabled_bits, Bitwise.bsl(1, bit)) != 0)
        end)

      expected_ids =
        existing_child_ids() ++
          for {{_setting, child}, bit} <- Enum.with_index(source_flags),
              Bitwise.band(enabled_bits, Bitwise.bsl(1, bit)) != 0,
              do: child

      assert child_ids(config) == expected_ids
    end
  end

  test "global ingestion disable dominates all per-source flags" do
    config = %{
      signal_config_with_solana_url()
      | enabled: false,
        drand_enabled: true,
        bluesky_enabled: true,
        ripe_enabled: true,
        solana_enabled: true
    }

    assert child_ids(config) == []
  end

  test "passes only source-specific validated settings to incremental children" do
    config = %{
      signal_config_with_solana_url()
      | drand_enabled: true,
        bluesky_enabled: true,
        ripe_enabled: true,
        solana_enabled: true
    }

    child_specs = child_specs(config)

    assert child_options(child_specs, DrandWorker) == [
             client_options: [origins: config.drand_relays]
           ]

    assert child_options(child_specs, BlueskySocket) == [url: config.bluesky_url]

    assert child_options(child_specs, RipeSocket) == [
             url: config.ripe_url,
             collectors: config.ripe_collectors
           ]

    assert child_options(child_specs, SolanaSocket) == [url: config.solana_url]
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

  test "test environment configuration starts no external incremental workers" do
    configured_ids = child_ids(signal_config())

    assert configured_ids == existing_child_ids()
    refute DrandWorker in configured_ids
    refute BlueskySocket in configured_ids
    refute RipeSocket in configured_ids
    refute SolanaSocket in configured_ids
  end

  defp child_ids(config), do: config |> child_specs() |> Enum.map(& &1.id)

  defp child_specs(config) do
    assert {:ok, {_flags, child_specs}} = SignalsSupervisor.init(config: config)
    child_specs
  end

  defp child_options(child_specs, child_id) do
    assert %{start: {^child_id, :start_link, [options]}} =
             Enum.find(child_specs, &(&1.id == child_id))

    options
  end

  defp existing_child_ids do
    [Worldloom.Signals.StreamSupervisor, WikimediaWorker, EarthquakeWorker, WeatherWorker]
  end

  defp signal_config do
    config = Application.fetch_env!(:worldloom, Worldloom.Signals)
    %{config | enabled: true}
  end

  defp signal_config_with_solana_url do
    signal_config()
    |> Map.from_struct()
    |> Map.put(:solana_url, "wss://solana.example.invalid/socket")
    |> Map.to_list()
    |> Config.from_keyword!(:test)
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
