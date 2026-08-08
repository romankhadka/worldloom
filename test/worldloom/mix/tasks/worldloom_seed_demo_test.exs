defmodule Worldloom.Mix.Tasks.WorldloomSeedDemoTest do
  use Worldloom.DataCase, async: false

  import ExUnit.CaptureIO

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.CoordinatorTestStore
  alias Worldloom.Loom.Event
  alias Worldloom.Loom.Store

  @base_now ~U[2026-08-03 12:34:56.000000Z]

  setup do
    {:ok, independent_repo} =
      Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 4)

    Process.unlink(independent_repo)
    Repo.put_dynamic_repo(independent_repo)

    unique_day = System.unique_integer([:positive, :monotonic])
    now = DateTime.add(@base_now, unique_day * 24 * 60 * 60, :second)
    window_start = previous_hour_start(now)
    window_end = DateTime.add(window_start, 1, :hour)

    start_supervised!({CoordinatorTestStore, delegate: Store, repo: independent_repo})

    previous_coordinator_state = :sys.get_state(Coordinator)
    snapshot = CoordinatorTestStore.live_snapshot(nil)

    :sys.replace_state(Coordinator, fn state ->
      %{
        state
        | store: CoordinatorTestStore,
          snapshot: snapshot,
          highest_sequence: snapshot.commit_watermark
      }
    end)

    on_exit(fn ->
      if Process.whereis(Coordinator) do
        :sys.replace_state(Coordinator, fn _state -> previous_coordinator_state end)
      end

      if Process.alive?(independent_repo) do
        Repo.put_dynamic_repo(independent_repo)

        Event
        |> where(
          [event],
          event.occurred_at >= ^window_start and event.occurred_at < ^window_end
        )
        |> Repo.delete_all()

        Supervisor.stop(independent_repo)
      end
    end)

    {:ok, now: now, window_start: window_start}
  end

  test "creates the same 120 offline demo events once across the previous UTC hour", %{
    now: now,
    window_start: window_start
  } do
    task_configuration =
      Application.get_env(:worldloom, Mix.Tasks.Worldloom.SeedDemo, [])

    signal_configuration = Application.fetch_env!(:worldloom, Worldloom.Signals)

    Application.put_env(:worldloom, Mix.Tasks.Worldloom.SeedDemo, clock: fn -> now end)

    on_exit(fn ->
      Application.put_env(:worldloom, Mix.Tasks.Worldloom.SeedDemo, task_configuration)
      Application.put_env(:worldloom, Worldloom.Signals, signal_configuration)
      Mix.Task.reenable("worldloom.seed_demo")
    end)

    assert Supervisor.which_children(Worldloom.Signals.Supervisor) == []

    first_output = run_task()
    first_events = demo_events(window_start)

    assert first_output =~ "Created 120 deterministic demo signals"
    assert length(first_events) == 120

    assert Enum.map(first_events, & &1.source) |> MapSet.new() ==
             MapSet.new(~w(wikimedia usgs open_meteo visitor))

    assert Enum.map(first_events, & &1.kind) |> MapSet.new() ==
             MapSet.new(~w(wikimedia earthquake weather tug knot illuminate))

    assert hd(first_events).occurred_at == window_start

    assert List.last(first_events).occurred_at ==
             DateTime.add(window_start, 59 * 60 + 30, :second)

    first_ids = Enum.map(first_events, & &1.id)
    second_output = run_task()
    second_events = demo_events(window_start)

    assert second_output =~ "Worldloom already has these 120 demo signals"
    assert Enum.map(second_events, & &1.id) == first_ids
    assert length(second_events) == 120
    assert Supervisor.which_children(Worldloom.Signals.Supervisor) == []
  end

  defp run_task do
    Mix.Task.reenable("worldloom.seed_demo")
    capture_io(fn -> Mix.Task.run("worldloom.seed_demo") end)
  end

  defp demo_events(window_start) do
    window_end = DateTime.add(window_start, 1, :hour)

    Event
    |> where(
      [event],
      event.occurred_at >= ^window_start and event.occurred_at < ^window_end
    )
    |> order_by([event], asc: event.id)
    |> Repo.all()
  end

  defp previous_hour_start(now) do
    now
    |> DateTime.shift_zone!("Etc/UTC")
    |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 6}})
    |> DateTime.add(-1, :hour)
  end
end
