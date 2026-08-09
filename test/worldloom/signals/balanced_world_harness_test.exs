defmodule Worldloom.Signals.BalancedWorldHarnessTest do
  use ExUnit.Case, async: false

  alias Worldloom.Signals.BlueskySocket
  alias Worldloom.Signals.DrandWorker
  alias Worldloom.Signals.EarthquakeWorker
  alias Worldloom.Signals.RipeSocket
  alias Worldloom.Signals.SolanaSocket
  alias Worldloom.Signals.WeatherWorker
  alias Worldloom.Signals.WikimediaWorker
  alias Worldloom.TestSupport.BalancedWorldHarness
  alias Worldloom.TestSupport.FakeUpstream

  test "configures one server-owned ingestion child for every fake source" do
    fake = start_supervised!({FakeUpstream, solana: true})
    urls = FakeUpstream.urls(fake)

    signal_config = BalancedWorldHarness.signal_config(urls)
    children = BalancedWorldHarness.source_children(urls)

    assert signal_config.enabled
    assert signal_config.drand_enabled
    assert signal_config.bluesky_enabled
    assert signal_config.ripe_enabled
    assert signal_config.solana_enabled
    assert signal_config.wikimedia_url == urls.wikimedia
    assert signal_config.usgs_url == urls.usgs
    assert signal_config.open_meteo_url == urls.open_meteo
    assert signal_config.bluesky_url == urls.bluesky
    assert signal_config.ripe_url == urls.ripe_ris
    assert signal_config.solana_url == urls.solana

    assert Enum.map(children, &Supervisor.child_spec(&1, []).id) == [
             Worldloom.Signals.StreamSupervisor,
             WikimediaWorker,
             EarthquakeWorker,
             WeatherWorker,
             DrandWorker,
             BlueskySocket,
             RipeSocket,
             SolanaSocket
           ]
  end

  test "the harness drand boundary requests and validates a fake public round" do
    fake = start_supervised!({FakeUpstream, solana: true})
    urls = FakeUpstream.urls(fake)
    clock = fn -> ~U[2026-08-08 16:00:03Z] end

    client =
      BalancedWorldHarness.DrandClient.new(
        urls.drand_origin,
        FakeUpstream.ca_file(),
        clock
      )

    assert BalancedWorldHarness.DrandClient.schedule(client) == %{
             period: 3,
             genesis_time: 1_786_204_800
           }

    assert {:ok, %{round: 2, render_identity: render_identity}} =
             BalancedWorldHarness.DrandClient.fetch_round(client, 2)

    assert render_identity =~ ~r/\A[0-9a-f]{64}\z/

    stats =
      urls.stats
      |> Req.get!(
        connect_options: [
          protocols: [:http1],
          transport_opts: [cacertfile: FakeUpstream.ca_file()]
        ]
      )
      |> Map.fetch!(:body)

    assert stats["drand"]["requests"] == 1
    assert stats["drand"]["emitted_windows"] == 1
  end

  test "the fake upstream remains owned by its supervisor after the harness caller returns" do
    {:ok, parent} = Supervisor.start_link([], strategy: :one_for_one)

    fake =
      Task.async(fn ->
        BalancedWorldHarness.start_fake_upstream!(parent, port: 0, cadence_ms: 50)
      end)
      |> Task.await()

    assert Process.alive?(fake)
    assert %{stats: stats_url, solana: solana_url} = FakeUpstream.urls(fake)
    assert is_binary(stats_url)
    assert is_binary(solana_url)
  end
end
