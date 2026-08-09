defmodule Worldloom.Mix.Tasks.WorldloomProvidersSmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Worldloom.Providers.Smoke

  @workflow Path.expand(
              "../../../../.github/workflows/provider-contract.yml",
              __DIR__
            )

  test "returns one ordered pass or coarse failure per supported provider" do
    probes = [
      drand: fn -> :ok end,
      bluesky: fn -> {:error, :protocol} end,
      ripe: fn -> {:error, :unavailable} end
    ]

    assert Smoke.check(probes: probes, timeout: 100) == [
             drand: :ok,
             bluesky: {:error, :protocol},
             ripe: {:error, :transport}
           ]
  end

  test "runs probes concurrently and bounds every provider by one deadline" do
    never_returns = fn ->
      receive do
      after
        :infinity -> :ok
      end
    end

    started_at = System.monotonic_time(:millisecond)

    outcomes =
      Smoke.check(
        probes: [drand: never_returns, bluesky: never_returns, ripe: never_returns],
        timeout: 20
      )

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert outcomes == [
             drand: {:error, :timeout},
             bluesky: {:error, :timeout},
             ripe: {:error, :timeout}
           ]

    assert elapsed < 500
  end

  test "kills linked probe resources when a provider reaches its deadline" do
    test_process = self()

    timed_probe = fn ->
      resource = spawn_link(fn -> Process.sleep(:infinity) end)
      send(test_process, {:probe_resource, resource})
      Process.sleep(:infinity)
    end

    assert Smoke.check(
             probes: [drand: timed_probe, bluesky: fn -> :ok end, ripe: fn -> :ok end],
             timeout: 20
           ) == [
             drand: {:error, :timeout},
             bluesky: :ok,
             ripe: :ok
           ]

    assert_receive {:probe_resource, resource}
    monitor = Process.monitor(resource)
    assert_receive {:DOWN, ^monitor, :process, ^resource, _reason}, 500
  end

  test "prints only provider and status when every contract passes" do
    output =
      run_task_with(
        drand: fn -> :ok end,
        bluesky: fn -> :ok end,
        ripe: fn -> :ok end
      )

    assert output == "drand ok\nbluesky ok\nripe ok\n"
  end

  test "raises on drift without exposing endpoint query cursor payload or response body" do
    test_process = self()

    private_markers = [
      "wss://private.example/subscribe?cursor=1786204800000000",
      "private-provider-payload",
      "private-response-body"
    ]

    output =
      capture_io(fn ->
        error =
          assert_raise Mix.Error, fn ->
            run_task(
              drand: fn ->
                raise "wss://private.example/subscribe?cursor=1786204800000000"
              end,
              bluesky: fn -> {:error, "private-provider-payload"} end,
              ripe: fn -> throw("private-response-body") end
            )
          end

        send(test_process, {:task_error, error})
      end)

    assert_receive {:task_error, error}
    assert Exception.message(error) == "provider contract smoke check failed"
    assert output == "drand failed internal\nbluesky failed protocol\nripe failed internal\n"

    for marker <- private_markers do
      refute output =~ marker
      refute Exception.message(error) =~ marker
    end
  end

  test "schedules the read-only command outside push and pull-request CI" do
    workflow = File.read!(@workflow)

    assert workflow =~ "schedule:"
    assert workflow =~ "workflow_dispatch:"
    assert workflow =~ "mix worldloom.providers.smoke"
    assert workflow =~ "contents: read"
    refute Regex.match?(~r/^\s+push:/m, workflow)
    refute Regex.match?(~r/^\s+pull_request:/m, workflow)
    refute workflow =~ "upload-artifact"
    refute workflow =~ "solana"
  end

  defp run_task_with(probes) do
    capture_io(fn -> run_task(probes) end)
  end

  defp run_task(probes) do
    prior_configuration = Application.get_env(:worldloom, Smoke, [])
    Application.put_env(:worldloom, Smoke, probes: probes, timeout: 100)
    Mix.Task.reenable("worldloom.providers.smoke")

    try do
      Mix.Task.run("worldloom.providers.smoke")
    after
      Application.put_env(:worldloom, Smoke, prior_configuration)
      Mix.Task.reenable("worldloom.providers.smoke")
    end
  end
end
