defmodule Worldloom.Mix.Tasks.WorldloomSeedDemoTest do
  use Worldloom.DataCase, async: false

  import ExUnit.CaptureIO

  alias Worldloom.Loom.Store

  @now ~U[2026-08-03 12:34:56.000000Z]

  test "creates the same 120 offline demo events once across the previous UTC hour" do
    task_configuration =
      Application.get_env(:worldloom, Mix.Tasks.Worldloom.SeedDemo, [])

    signal_configuration = Application.fetch_env!(:worldloom, Worldloom.Signals)

    Application.put_env(:worldloom, Mix.Tasks.Worldloom.SeedDemo, clock: fn -> @now end)

    on_exit(fn ->
      Application.put_env(:worldloom, Mix.Tasks.Worldloom.SeedDemo, task_configuration)
      Application.put_env(:worldloom, Worldloom.Signals, signal_configuration)
      Mix.Task.reenable("worldloom.seed_demo")
    end)

    assert Supervisor.which_children(Worldloom.Signals.Supervisor) == []

    first_output = run_task()
    first_events = Store.latest(600)

    assert first_output =~ "Created 120 deterministic demo signals"
    assert length(first_events) == 120

    assert Enum.map(first_events, & &1.source) |> MapSet.new() ==
             MapSet.new(~w(wikimedia usgs open_meteo visitor))

    assert Enum.map(first_events, & &1.kind) |> MapSet.new() ==
             MapSet.new(~w(wikimedia earthquake weather tug knot illuminate))

    assert hd(first_events).occurred_at == ~U[2026-08-03 11:00:00.000000Z]
    assert List.last(first_events).occurred_at == ~U[2026-08-03 11:59:30.000000Z]

    first_ids = Enum.map(first_events, & &1.id)
    second_output = run_task()
    second_events = Store.latest(600)

    assert second_output =~ "Worldloom already has these 120 demo signals"
    assert Enum.map(second_events, & &1.id) == first_ids
    assert length(second_events) == 120
    assert Supervisor.which_children(Worldloom.Signals.Supervisor) == []
  end

  defp run_task do
    Mix.Task.reenable("worldloom.seed_demo")
    capture_io(fn -> Mix.Task.run("worldloom.seed_demo") end)
  end
end
