defmodule WorldloomWeb.WorldLiveTest do
  use WorldloomWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.CoordinatorTestStore
  alias Worldloom.Loom.Event
  alias Worldloom.Loom.Instruction
  alias Worldloom.Loom.LiveSnapshot
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store
  alias Worldloom.Repo
  alias Worldloom.Signals.HealthMonitor

  setup do
    start_supervised!(
      {CoordinatorTestStore,
       delegate: Store,
       commit_snapshot: CoordinatorTestStore.empty_snapshot(Store.highest_sequence())}
    )

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
    end)

    :ok
  end

  test "serves every public mode with the stable loom skeleton", %{conn: conn} do
    [_event] = seed_events(1)

    {:ok, live_view, html} = live(conn, "/")

    assert html =~ "data-instruction-count=\"1\""
    assert has_element?(live_view, "#loom-canvas[data-gesture-lane='0.5']")
    assert has_element?(live_view, "#loom-canvas[data-live='true']")

    for selector <- [
          "#worldloom",
          "#loom-canvas",
          "#live-edge",
          "#viewer-count",
          "#signal-legend",
          "#gesture-dock",
          "#timeline",
          "#archive-panel",
          "#about-panel",
          "#accessible-formations"
        ] do
      assert has_element?(live_view, selector)
    end

    assert {:ok, archive_view, _html} = live(conn, "/chapters")
    assert has_element?(archive_view, "#archive-panel[data-active]")
    assert has_element?(archive_view, "#loom-canvas[data-live='false']")

    assert {:ok, about_view, _html} = live(conn, "/about")
    assert has_element?(about_view, "#about-panel[data-active]")
    assert has_element?(about_view, "#loom-canvas[data-live='false']")
  end

  test "stages the artwork without rendering empty detail chrome", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    assert has_element?(live_view, "#worldloom-introduction h1", "The world is weaving itself")
    assert has_element?(live_view, "#worldloom-introduction", "Public signals")
    assert has_element?(live_view, "#gesture-dock", "Touch the loom")
    refute has_element?(live_view, "#signal-detail")
  end

  test "exposes separate initial snapshot fields with scaffold and ambient", %{conn: conn} do
    snapshot = synthetic_live_snapshot_fixture()
    put_current_snapshot(snapshot)

    {:ok, live_view, _html} = live(conn, "/")

    assert has_element?(live_view, "#loom-canvas[data-window-end='2026-08-08T12:01:00Z']")
    assert has_element?(live_view, "#loom-canvas[data-commit-watermark='906']")
    assert render(live_view) =~ "data-display-events"
    assert render(live_view) =~ "data-memory-events"
    assert has_element?(live_view, "#loom-canvas[data-instruction-count='2']")
    assert has_element?(live_view, "#loom-canvas[data-scaffold-count='2']")
    assert has_element?(live_view, "#worldloom[data-event-window-size='4']")

    canvas = live_view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#loom-canvas")

    [encoded_display_events] = LazyHTML.attribute(canvas, "data-display-events")
    [encoded_memory_events] = LazyHTML.attribute(canvas, "data-memory-events")
    [encoded_ambient] = LazyHTML.attribute(canvas, "data-ambient")
    [encoded_scaffold] = LazyHTML.attribute(canvas, "data-scaffold")

    display_events = Jason.decode!(encoded_display_events)
    memory_events = Jason.decode!(encoded_memory_events)
    ambient = Jason.decode!(encoded_ambient)
    scaffold = Jason.decode!(encoded_scaffold)

    assert source_sequence_pairs(display_events) == source_sequence_pairs(snapshot.display_events)
    assert source_sequence_pairs(memory_events) == source_sequence_pairs(snapshot.memory_events)
    assert source_sequence_pairs(scaffold) == source_sequence_pairs(snapshot.display_events)

    assert MapSet.disjoint?(
             MapSet.new(source_sequence_pairs(display_events)),
             MapSet.new(source_sequence_pairs(memory_events))
           )

    assert {ambient["source"], ambient["sequence"]} ==
             {snapshot.ambient.source, snapshot.ambient.id}

    assert ambient["kind"] == "weather"
    refute {ambient["source"], ambient["sequence"]} in source_sequence_pairs(display_events)
    refute {ambient["source"], ambient["sequence"]} in source_sequence_pairs(memory_events)
  end

  test "visitor-only live display retains the latest bounded public scaffold", %{conn: conn} do
    public_events = seed_events(15, ~U[2026-08-08 11:58:00Z])
    visitor_events = seed_visitor_events(2, ~U[2026-08-08 12:00:50Z])

    put_current_snapshot(%LiveSnapshot{
      window_end: ~U[2026-08-08 12:01:00Z],
      commit_watermark: List.last(visitor_events).id,
      display_events: visitor_events,
      memory_events: [],
      ambient: nil
    })

    {{:ok, live_view, _html}, scaffold_query_count} =
      count_function_calls({Store, :wikimedia_before, 2}, fn -> live(conn, "/") end)

    canvas = live_view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#loom-canvas")
    [encoded_scaffold] = LazyHTML.attribute(canvas, "data-scaffold")
    scaffold = Jason.decode!(encoded_scaffold)
    expected_public_ids = public_events |> Enum.take(-12) |> Enum.map(& &1.id)

    assert Enum.map(scaffold, & &1["sequence"]) == expected_public_ids
    assert Enum.all?(scaffold, &(&1["source"] == "wikimedia"))
    assert scaffold_query_count == 2
    assert has_element?(live_view, "#worldloom[data-event-window-size='2']")
    assert accessible_sequence_ids(live_view) == Enum.map(visitor_events, & &1.id)

    for public_event <- Enum.take(public_events, -12) do
      refute has_element?(live_view, "#formation-#{public_event.id}")
    end
  end

  test "snapshot updates merge and retain bounded public scaffold without Store queries", %{
    conn: conn
  } do
    public_events = seed_events(12, ~U[2026-08-08 11:58:00Z])
    visitor_events = seed_visitor_events(2, ~U[2026-08-08 12:00:50Z])

    initial_snapshot = %LiveSnapshot{
      window_end: ~U[2026-08-08 12:01:00Z],
      commit_watermark: List.last(visitor_events).id,
      display_events: visitor_events,
      memory_events: [],
      ambient: nil
    }

    put_current_snapshot(initial_snapshot)
    {:ok, live_view, _html} = live(conn, "/")
    [new_public_event] = seed_events(1, ~U[2026-08-08 12:00:55Z])

    mixed_snapshot = %{
      initial_snapshot
      | commit_watermark: new_public_event.id,
        display_events: visitor_events ++ [new_public_event]
    }

    visitor_only_snapshot = %{
      mixed_snapshot
      | commit_watermark: new_public_event.id + 1,
        display_events: visitor_events
    }

    {{merged_scaffold_ids, retained_scaffold_ids}, scaffold_query_count} =
      count_function_calls({Store, :wikimedia_before, 2}, fn ->
        put_current_snapshot(mixed_snapshot)
        send(live_view.pid, {:loom_snapshot, mixed_snapshot})
        assert_push_event live_view, "worldloom:snapshot", %{}
        merged_scaffold_ids = live_assign(live_view, :scaffold) |> instruction_sequence_ids()

        put_current_snapshot(visitor_only_snapshot)
        send(live_view.pid, {:loom_snapshot, visitor_only_snapshot})
        assert_push_event live_view, "worldloom:snapshot", %{}
        retained_scaffold_ids = live_assign(live_view, :scaffold) |> instruction_sequence_ids()

        {merged_scaffold_ids, retained_scaffold_ids}
      end)

    expected_scaffold_ids =
      public_events
      |> Enum.drop(1)
      |> Kernel.++([new_public_event])
      |> Enum.map(& &1.id)

    assert merged_scaffold_ids == expected_scaffold_ids
    assert retained_scaffold_ids == expected_scaffold_ids
    assert scaffold_query_count == 0
    assert accessible_sequence_ids(live_view) == Enum.map(visitor_events, & &1.id)

    for public_sequence <- expected_scaffold_ids do
      refute has_element?(live_view, "#formation-#{public_sequence}")
    end
  end

  test "validates chapter permalinks and keeps historical views read-only", %{conn: conn} do
    [event] = seed_events(1, ~U[2026-08-03 12:00:00.000000Z])
    path = "/chapters/2026-08-03/#{event.id}"

    {:ok, chapter_view, _html} = live(conn, path)
    assert has_element?(chapter_view, "#gesture-dock[aria-disabled='true']")
    assert has_element?(chapter_view, "#return-live")

    for gesture <- ["tug", "knot", "illuminate"] do
      assert has_element?(chapter_view, "#gesture-#{gesture}[disabled]")
    end

    send(chapter_view.pid, {:loom_snapshot, seed_live_snapshot_fixture()})

    refute_push_event chapter_view, "worldloom:snapshot", _payload

    for invalid_path <- [
          "/chapters/not-a-date/#{event.id}",
          "/chapters/2026-08-04/#{event.id}",
          "/chapters/2026-08-03/not-a-sequence",
          "/chapters/2026-08-03/#{event.id + 100_000}"
        ] do
      assert_error_sent 404, fn -> get(recycle(conn), invalid_path) end
    end
  end

  test "derives live and chapter state from browser history patches", %{conn: conn} do
    [selected_event, _later_event] = seed_events(2, ~U[2026-08-03 15:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    chapter_path = "/chapters/2026-08-03/#{selected_event.id}"
    render_hook(live_view, "select-formation", %{"sequence" => selected_event.id})

    assert_patch live_view, chapter_path
    assert has_element?(live_view, "#worldloom[data-mode='chapter']")
    assert has_element?(live_view, "#signal-detail", "Public formation 1")
    assert has_element?(live_view, "#gesture-dock[aria-disabled='true']")

    render_patch(live_view, "/")

    assert has_element?(live_view, "#worldloom[data-mode='live']")
    refute has_element?(live_view, "#signal-detail")
    assert has_element?(live_view, "#gesture-dock[aria-disabled='false']")

    for gesture <- ["tug", "knot", "illuminate"] do
      refute has_element?(live_view, "#gesture-#{gesture}[disabled]")
    end

    live_view |> element("#share-worldloom") |> render_click()
    assert_push_event live_view, "worldloom:copy-link", %{url: root_url}
    assert URI.parse(root_url).path == "/"

    [broadcast_event] = seed_events(1, ~U[2026-08-03 16:00:00.000000Z])
    broadcast_snapshot = Coordinator.current_snapshot()

    send(live_view.pid, {:loom_snapshot, broadcast_snapshot})

    assert_push_event live_view, "worldloom:snapshot", %{
      display_events: [%{"sequence" => broadcast_sequence}]
    }

    assert broadcast_sequence == broadcast_event.id
    refute_push_event live_view, "worldloom:event", _legacy_event
    refute_push_event live_view, "worldloom:catch-up", _legacy_catch_up

    render_patch(live_view, chapter_path)

    assert has_element?(live_view, "#worldloom[data-mode='chapter']")
    assert has_element?(live_view, "#loom-canvas[data-live='false']")
    assert has_element?(live_view, "#signal-detail", "Public formation 1")
    assert has_element?(live_view, "#gesture-dock[aria-disabled='true']")
    assert_push_event live_view, "worldloom:reload", %{selected_sequence: selected_sequence}
    assert selected_sequence == selected_event.id

    render_patch(live_view, "/")

    assert has_element?(live_view, "#worldloom[data-mode='live']")
    refute has_element?(live_view, "#signal-detail")
    assert has_element?(live_view, "#formation-#{broadcast_event.id}")
  end

  test "subscribes before taking the live snapshot after browser Back", %{conn: conn} do
    [selected_event] = seed_events(1, ~U[2026-08-03 15:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "select-formation", %{"sequence" => selected_event.id})
    assert_patch live_view, "/chapters/2026-08-03/#{selected_event.id}"

    calls =
      trace_route_calls(live_view.pid, fn ->
        render_patch(live_view, "/")
      end)

    assert calls == [
             {Phoenix.PubSub, :subscribe, [Worldloom.PubSub, Worldloom.Loom.Coordinator.topic()]},
             {Coordinator, :current_snapshot, []}
           ]
  end

  test "loads each initial live lifecycle snapshot once", %{conn: conn} do
    {{:ok, _live_view, _html}, snapshot_call_count} =
      count_function_calls({Coordinator, :current_snapshot, 0}, fn -> live(conn, "/") end)

    assert snapshot_call_count == 2
  end

  test "loads each initial chapter lifecycle event window once", %{conn: conn} do
    [selected_event] = seed_events(1, ~U[2026-08-03 15:00:00.000000Z])
    chapter_path = "/chapters/2026-08-03/#{selected_event.id}"

    {{:ok, _live_view, _html}, around_call_count} =
      count_function_calls({Store, :around, 2}, fn -> live(conn, chapter_path) end)

    assert around_call_count == 2
  end

  test "tracks only the aggregate connected viewer count", %{conn: conn} do
    {:ok, first_view, _html} = live(conn, "/")
    {:ok, second_view, _html} = live(recycle(conn), "/about")

    assert eventually(fn -> has_element?(first_view, "#viewer-count", "2") end)
    assert eventually(fn -> has_element?(second_view, "#viewer-count", "2") end)
  end

  test "atomically pushes live snapshots and rebuilds trust and accessibility", %{conn: conn} do
    _initial_snapshot = seed_live_snapshot_fixture()
    {:ok, live_view, _html} = live(conn, "/")

    updated_snapshot = seed_live_snapshot_fixture(~U[2026-08-08 12:02:00Z])
    put_current_snapshot(updated_snapshot)
    send(live_view.pid, {:loom_snapshot, updated_snapshot})

    assert_push_event live_view, "worldloom:snapshot", payload

    assert Map.keys(payload) |> Enum.sort() ==
             [
               :ambient,
               :commit_watermark,
               :display_events,
               :memory_events,
               :snapshot_version,
               :window_end
             ]

    assert payload.snapshot_version == 1
    assert payload.window_end == "2026-08-08T12:02:00Z"
    assert payload.commit_watermark == updated_snapshot.commit_watermark

    assert payload.display_events ==
             Enum.map(updated_snapshot.display_events, &Instruction.from_event/1)

    assert payload.memory_events ==
             Enum.map(updated_snapshot.memory_events, &Instruction.from_event/1)

    assert payload.ambient == Instruction.from_event(updated_snapshot.ambient)
    refute_push_event live_view, "worldloom:snapshot", _duplicate_snapshot
    refute_push_event live_view, "worldloom:event", _legacy_event
    refute_push_event live_view, "worldloom:catch-up", _legacy_catch_up
    refute_push_event live_view, "worldloom:reload", _legacy_reload

    trusted_events = updated_snapshot.display_events ++ updated_snapshot.memory_events
    trusted_pairs = source_sequence_pairs(trusted_events)

    assert accessible_sequence_ids(live_view) == Enum.map(trusted_events, & &1.id)

    for {source, sequence} <- trusted_pairs do
      assert has_element?(live_view, "#formation-#{sequence}[phx-value-sequence='#{sequence}']")
      assert Enum.any?(trusted_events, &(&1.source == source and &1.id == sequence))
    end

    refute has_element?(live_view, "#formation-#{updated_snapshot.ambient.id}")

    [display_event | _events] = updated_snapshot.display_events
    render_hook(live_view, "select-formation", %{"sequence" => display_event.id})
    assert_patch live_view, chapter_path(display_event)

    render_patch(live_view, "/")

    [memory_event | _events] = updated_snapshot.memory_events
    render_hook(live_view, "select-formation", %{"sequence" => memory_event.id})
    assert_patch live_view, chapter_path(memory_event)

    render_patch(live_view, "/")
    render_hook(live_view, "select-formation", %{"sequence" => updated_snapshot.ambient.id})
    assert has_element?(live_view, "#worldloom[data-mode='live']")
    refute has_element?(live_view, "#signal-detail")
  end

  test "late recovery advances only the snapshot commit watermark", %{conn: conn} do
    snapshot = seed_live_snapshot_fixture()
    {:ok, live_view, _html} = live(conn, "/")

    recovery_snapshot = %{snapshot | commit_watermark: snapshot.commit_watermark + 1}
    send(live_view.pid, {:loom_snapshot, recovery_snapshot})

    assert_push_event live_view, "worldloom:snapshot", %{
      window_end: "2026-08-08T12:01:00Z",
      commit_watermark: commit_watermark,
      display_events: display_events,
      memory_events: memory_events
    }

    assert commit_watermark == recovery_snapshot.commit_watermark
    assert display_events == Enum.map(snapshot.display_events, &Instruction.from_event/1)
    assert memory_events == Enum.map(snapshot.memory_events, &Instruction.from_event/1)
    refute_push_event live_view, "worldloom:event", _legacy_event
    refute_push_event live_view, "worldloom:catch-up", _legacy_catch_up
    refute_push_event live_view, "worldloom:reload", _legacy_reload
  end

  test "return-live refreshes the complete current snapshot including ambient", %{conn: conn} do
    _initial_snapshot = seed_live_snapshot_fixture()
    {:ok, live_view, _html} = live(conn, "/")
    current_snapshot = seed_live_snapshot_fixture(~U[2026-08-08 12:03:00Z])
    put_current_snapshot(current_snapshot)

    render_hook(live_view, "return-live", %{})

    assert_push_event live_view, "worldloom:return-live", payload
    assert payload == encoded_snapshot(current_snapshot)
  end

  test "return-live ignores queued stale snapshots and equal duplicates", %{conn: conn} do
    older_events = seed_events(2, ~U[2026-08-08 12:00:00Z])

    older_snapshot = %LiveSnapshot{
      window_end: ~U[2026-08-08 12:00:01Z],
      commit_watermark: List.last(older_events).id,
      display_events: older_events,
      memory_events: [],
      ambient: nil
    }

    put_current_snapshot(older_snapshot)
    {:ok, live_view, _html} = live(conn, "/")

    [older_event | _events] = older_events
    render_hook(live_view, "select-formation", %{"sequence" => older_event.id})
    assert_patch live_view, chapter_path(older_event)

    current_events = seed_events(2, ~U[2026-08-08 12:01:00Z])

    current_snapshot = %LiveSnapshot{
      window_end: ~U[2026-08-08 12:01:01Z],
      commit_watermark: List.last(current_events).id,
      display_events: current_events,
      memory_events: [],
      ambient: nil
    }

    put_current_snapshot(current_snapshot)
    render_patch(live_view, "/")
    assert_push_event live_view, "worldloom:return-live", return_payload
    assert return_payload == encoded_snapshot(current_snapshot)

    send(live_view.pid, {:loom_snapshot, older_snapshot})
    refute_push_event live_view, "worldloom:snapshot", _stale_payload
    assert live_assign(live_view, :commit_watermark) == current_snapshot.commit_watermark
    assert accessible_sequence_ids(live_view) == Enum.map(current_events, & &1.id)

    send(live_view.pid, {:loom_snapshot, current_snapshot})
    refute_push_event live_view, "worldloom:snapshot", _duplicate_payload
    assert live_assign(live_view, :commit_watermark) == current_snapshot.commit_watermark
    assert accessible_sequence_ids(live_view) == Enum.map(current_events, & &1.id)
  end

  test "uses a safe fallback cursor for invalid throttled history requests", %{conn: conn} do
    events = seed_events(405)

    put_current_snapshot(%LiveSnapshot{
      window_end: ~U[2026-08-03 12:06:44Z],
      commit_watermark: List.last(events).id,
      display_events: Enum.take(events, -400),
      memory_events: [],
      ambient: nil
    })

    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "history-before", %{"before" => "not-a-sequence"})

    assert_push_event live_view, "worldloom:history", %{
      instructions: instructions,
      scaffold: scaffold,
      archive_start?: true
    }

    expected_sequences = events |> Enum.take(5) |> Enum.map(& &1.id)
    assert Enum.map(instructions, & &1["sequence"]) == expected_sequences
    assert Enum.map(scaffold, & &1["sequence"]) == expected_sequences

    render_hook(live_view, "history-before", %{"before" => 1})
    refute_push_event live_view, "worldloom:history", _throttled
  end

  test "uses the safe history fallback for an oversized integer cursor", %{conn: conn} do
    events = seed_events(405)

    put_current_snapshot(%LiveSnapshot{
      window_end: ~U[2026-08-03 12:06:44Z],
      commit_watermark: List.last(events).id,
      display_events: Enum.take(events, -400),
      memory_events: [],
      ambient: nil
    })

    {:ok, live_view, _html} = live(conn, "/")
    render_hook(live_view, "history-before", %{"before" => 9_223_372_036_854_775_808})

    assert_push_event live_view, "worldloom:history", %{instructions: instructions}
    assert instruction_sequence_ids(instructions) == Enum.map(Enum.take(events, 5), & &1.id)
  end

  test "uses the safe history fallback for an oversized decimal cursor", %{conn: conn} do
    events = seed_events(405)

    put_current_snapshot(%LiveSnapshot{
      window_end: ~U[2026-08-03 12:06:44Z],
      commit_watermark: List.last(events).id,
      display_events: Enum.take(events, -400),
      memory_events: [],
      ambient: nil
    })

    {:ok, live_view, _html} = live(conn, "/")
    render_hook(live_view, "history-before", %{"before" => "9223372036854775808"})

    assert_push_event live_view, "worldloom:history", %{instructions: instructions}
    assert instruction_sequence_ids(instructions) == Enum.map(Enum.take(events, 5), & &1.id)
  end

  test "empty maximum-watermark snapshots page inclusively through safe fallbacks", %{
    conn: conn
  } do
    maximum_sequence = 9_223_372_036_854_775_807

    {1, [maximum_event]} =
      Repo.insert_all(
        Event,
        [
          %{
            id: maximum_sequence,
            kind: "wikimedia",
            source: "wikimedia",
            external_id: "world-live-maximum-signed-bigint-sequence",
            occurred_at: ~U[2026-08-03 12:00:00.000000Z],
            render_version: 1,
            render_seed: 1,
            lane: 0.4,
            intensity: 0.6,
            payload: %{
              "summary" => "Maximum sequence entered the weave",
              "visual" => %{"bend" => 0.1, "pulse" => 0.2, "spread" => 0.3}
            },
            inserted_at: ~U[2026-08-03 12:00:00.000000Z]
          }
        ],
        returning: true
      )

    put_current_snapshot(%LiveSnapshot{
      window_end: nil,
      commit_watermark: maximum_sequence,
      display_events: [],
      memory_events: [],
      ambient: nil
    })

    payloads = [
      %{},
      %{"before" => "not-a-sequence"},
      %{"before" => maximum_sequence + 1},
      %{"before" => Integer.to_string(maximum_sequence + 1)}
    ]

    live_views =
      Enum.map(payloads, fn payload ->
        {:ok, live_view, _html} = live(recycle(conn), "/")
        render_hook(live_view, "history-before", payload)
        assert_push_event live_view, "worldloom:history", %{instructions: instructions}
        assert List.last(instructions)["sequence"] == maximum_event.id
        assert Map.has_key?(live_assign(live_view, :trusted_history_events), maximum_event.id)
        live_view
      end)

    [live_view | _views] = live_views
    render_hook(live_view, "select-formation", %{"sequence" => maximum_event.id})
    assert_patch live_view, chapter_path(maximum_event)
  end

  test "keeps live and delayed history windows selectable across viewport changes", %{conn: conn} do
    events = seed_events(1_000)
    history_events = Enum.take(events, 400)
    live_events = Enum.take(events, -600)

    put_current_snapshot(%LiveSnapshot{
      window_end: List.last(live_events).occurred_at,
      commit_watermark: List.last(live_events).id,
      display_events: live_events,
      memory_events: [],
      ambient: nil
    })

    {:ok, live_view, _html} = live(conn, "/")
    render_hook(live_view, "viewport-state", %{"at_live_edge" => false})
    render_hook(live_view, "history-before", %{"before" => hd(live_events).id})
    render_hook(live_view, "viewport-state", %{"at_live_edge" => true})

    assert_push_event live_view, "worldloom:history", %{instructions: instructions}
    assert instruction_sequence_ids(instructions) == Enum.map(history_events, & &1.id)

    live_event = List.last(live_events)
    [oldest_history_event | _events] = history_events

    render_hook(live_view, "select-formation", %{"sequence" => live_event.id})
    assert_patch live_view, chapter_path(live_event)

    {:ok, history_view, _html} = live(recycle(conn), "/")
    render_hook(history_view, "viewport-state", %{"at_live_edge" => false})
    render_hook(history_view, "history-before", %{"before" => hd(live_events).id})
    render_hook(history_view, "viewport-state", %{"at_live_edge" => true})
    assert_push_event history_view, "worldloom:history", _history_payload

    assert map_size(live_assign(history_view, :trusted_events)) == 600
    assert map_size(live_assign(history_view, :trusted_history_events)) == 400

    render_hook(history_view, "select-formation", %{"sequence" => oldest_history_event.id})
    assert_patch history_view, chapter_path(oldest_history_event)

    render_patch(history_view, chapter_path(oldest_history_event))
    assert live_assign(history_view, :trusted_history_events) == %{}
  end

  test "replays a discarded history page from the browser cursor", %{conn: conn} do
    events = seed_events(1_400)
    expected_page = Enum.slice(events, 400, 400)
    live_events = Enum.take(events, -600)
    original_before = hd(live_events).id

    put_current_snapshot(%LiveSnapshot{
      window_end: List.last(live_events).occurred_at,
      commit_watermark: List.last(live_events).id,
      display_events: live_events,
      memory_events: [],
      ambient: nil
    })

    {:ok, live_view, _html} = live(conn, "/")
    render_hook(live_view, "viewport-state", %{"at_live_edge" => false})
    render_hook(live_view, "history-before", %{"before" => original_before})

    assert_push_event live_view, "worldloom:history", %{instructions: first_instructions}
    assert instruction_sequence_ids(first_instructions) == Enum.map(expected_page, & &1.id)

    render_hook(live_view, "viewport-state", %{"at_live_edge" => true})
    allow_history_request(live_view)

    render_hook(live_view, "history-before", %{
      "before" => Integer.to_string(original_before)
    })

    assert_push_event live_view, "worldloom:history", %{instructions: replayed_instructions}
    assert instruction_sequence_ids(replayed_instructions) == Enum.map(expected_page, & &1.id)

    replayed_event = hd(expected_page)
    assert map_size(live_assign(live_view, :trusted_history_events)) == 400
    render_hook(live_view, "select-formation", %{"sequence" => replayed_event.id})
    assert_patch live_view, chapter_path(replayed_event)
  end

  test "bounds history authorization without evicting live trust", %{conn: conn} do
    events = seed_events(1_612)
    live_events = Enum.slice(events, 1_000, 600)
    scaffold_only_event = List.last(events)
    ambient = seed_weather_event(~U[2026-08-03 13:00:00Z])

    put_current_snapshot(%LiveSnapshot{
      window_end: List.last(live_events).occurred_at,
      commit_watermark: ambient.id,
      display_events: live_events,
      memory_events: [],
      ambient: ambient
    })

    {:ok, live_view, _html} = live(conn, "/")

    assert Enum.any?(live_assign(live_view, :scaffold), fn instruction ->
             instruction["sequence"] == scaffold_only_event.id
           end)

    first_cursor = hd(live_events).id
    render_hook(live_view, "history-before", %{"before" => first_cursor})
    assert_push_event live_view, "worldloom:history", %{instructions: first_page}

    allow_history_request(live_view)
    second_cursor = hd(first_page)["sequence"]
    render_hook(live_view, "history-before", %{"before" => second_cursor})
    assert_push_event live_view, "worldloom:history", %{instructions: second_page}

    allow_history_request(live_view)
    third_cursor = hd(second_page)["sequence"]
    render_hook(live_view, "history-before", %{"before" => third_cursor})
    assert_push_event live_view, "worldloom:history", %{instructions: third_page}

    assert length(first_page) == 400
    assert length(second_page) == 400
    assert length(third_page) == 200

    live_trust = live_assign(live_view, :trusted_events)
    history_trust = live_assign(live_view, :trusted_history_events)

    assert map_size(live_trust) == 600
    assert MapSet.new(Map.keys(live_trust)) == MapSet.new(live_events, & &1.id)
    assert map_size(history_trust) == 600
    assert MapSet.new(Map.keys(history_trust)) == MapSet.new(Enum.take(events, 600), & &1.id)
    assert map_size(live_trust) + map_size(history_trust) == 1_200

    for unauthorized_sequence <- [ambient.id, scaffold_only_event.id, ambient.id + 10_000] do
      render_hook(live_view, "select-formation", %{"sequence" => unauthorized_sequence})
      refute_patched live_view
    end

    render_hook(live_view, "return-live", %{})
    assert_push_event live_view, "worldloom:return-live", _payload
    assert live_assign(live_view, :trusted_history_events) == %{}
    assert map_size(live_assign(live_view, :trusted_events)) == 600
  end

  test "history paging starts before primary display rather than older contextual memory", %{
    conn: conn
  } do
    [contextual_memory] = seed_visitor_events(1, ~U[2026-08-08 11:58:00Z])
    intervening_events = seed_events(3, ~U[2026-08-08 11:59:00Z])
    display_events = seed_events(2, ~U[2026-08-08 12:00:50Z])

    put_current_snapshot(%LiveSnapshot{
      window_end: ~U[2026-08-08 12:01:00Z],
      commit_watermark: List.last(display_events).id,
      display_events: display_events,
      memory_events: [contextual_memory],
      ambient: nil
    })

    {:ok, live_view, _html} = live(conn, "/")
    render_hook(live_view, "history-before", %{})

    assert_push_event live_view, "worldloom:history", %{instructions: instructions}

    assert Enum.map(instructions, & &1["sequence"]) ==
             Enum.map([contextual_memory | intervening_events], & &1.id)
  end

  test "history paging starts from the commit watermark when primary display is empty", %{
    conn: conn
  } do
    committed_events = seed_events(3, ~U[2026-08-08 11:59:00Z])

    put_current_snapshot(%LiveSnapshot{
      window_end: nil,
      commit_watermark: List.last(committed_events).id,
      display_events: [],
      memory_events: [],
      ambient: nil
    })

    {:ok, live_view, _html} = live(conn, "/")
    render_hook(live_view, "history-before", %{})

    assert_push_event live_view, "worldloom:history", %{instructions: instructions}
    assert Enum.map(instructions, & &1["sequence"]) == Enum.map(committed_events, & &1.id)
  end

  test "receives shared safe feed health without polling in the view", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    safe_health = %{
      wikimedia: %{state: :live, observed_at: ~U[2026-08-03 12:00:00Z]},
      usgs: %{state: :quiet, observed_at: nil},
      open_meteo: %{state: :stale, observed_at: nil}
    }

    Phoenix.PubSub.broadcast(
      Worldloom.PubSub,
      HealthMonitor.topic(),
      {:feed_health, safe_health}
    )

    assert eventually(fn ->
             has_element?(live_view, "#signal-legend[data-usgs-state='quiet']") and
               has_element?(live_view, "#signal-legend[data-weather-state='stale']")
           end)
  end

  test "exposes direct gesture actions and adjusts the lane with keyboard events", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    for {gesture, label, description} <- [
          {"tug", "Tug", "Bend a strand"},
          {"knot", "Knot", "Join two paths"},
          {"illuminate", "Illuminate", "Awaken a junction"}
        ] do
      assert has_element?(
               live_view,
               "#gesture-#{gesture}[type='submit'][name='gesture'][value='#{gesture}'][aria-label='#{label}'][aria-describedby='gesture-#{gesture}-description']"
             )

      assert has_element?(live_view, "#gesture-#{gesture} .gesture-copy strong", label)

      assert has_element?(
               live_view,
               "#gesture-#{gesture}-description",
               description
             )
    end

    refute has_element?(live_view, "[aria-pressed]")
    refute has_element?(live_view, "#weave-gesture")

    render_hook(live_view, "lane-key", %{"key" => "ArrowUp"})
    assert has_element?(live_view, "#gesture-lane[value='0.55']")

    render_hook(live_view, "lane-key", %{"key" => "ArrowLeft"})
    assert has_element?(live_view, "#gesture-lane[value='0.5']")
  end

  test "gesture buttons commit directly at the current lane", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    live_view
    |> form("#gesture-lane-form", %{"lane" => "0.7"})
    |> render_submit(%{"gesture" => "illuminate"})

    assert_push_event live_view, "worldloom:gesture-accepted", %{"sequence" => sequence}
    assert is_integer(sequence)

    assert_push_event live_view, "worldloom:snapshot", %{
      commit_watermark: ^sequence,
      window_end: nil
    }

    refute_push_event live_view, "worldloom:event", _legacy_event

    assert has_element?(live_view, "#gesture-status", "Gesture joined the living edge")
    assert has_element?(live_view, "#gesture-status", "Gesture controls return in 30 seconds.")
    assert has_element?(live_view, "#gesture-cooldown-ring[data-seconds='30']")

    for gesture <- ["tug", "knot", "illuminate"] do
      assert has_element?(live_view, "#gesture-#{gesture}[disabled]")
    end

    send(live_view.pid, :gesture_ready)

    assert eventually(fn ->
             has_element?(live_view, "#gesture-status", "Choose an action for the live edge") and
               not has_element?(live_view, "#gesture-cooldown-ring") and
               Enum.all?(["tug", "knot", "illuminate"], fn gesture ->
                 not has_element?(live_view, "#gesture-#{gesture}[disabled]")
               end)
           end)

    live_view
    |> form("#gesture-lane-form", %{"lane" => "0.5"})
    |> render_submit(%{"gesture" => "knot"})

    assert has_element?(live_view, "#gesture-status", "Try again in")

    for gesture <- ["tug", "knot", "illuminate"] do
      assert has_element?(live_view, "#gesture-#{gesture}[disabled]")
    end

    send(live_view.pid, {:gesture_ready, make_ref()})

    assert eventually(fn ->
             Enum.all?(["tug", "knot", "illuminate"], fn gesture ->
               has_element?(live_view, "#gesture-#{gesture}[disabled]")
             end)
           end)
  end

  test "keeps cooldown feedback truthful across live and chapter routes", %{conn: conn} do
    [selected_event] = seed_events(1, ~U[2026-08-03 17:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    live_view
    |> form("#gesture-lane-form", %{"lane" => "0.6"})
    |> render_submit(%{"gesture" => "tug"})

    assert has_element?(live_view, "#gesture-status", "Gesture controls return in 30 seconds.")

    chapter_path = "/chapters/2026-08-03/#{selected_event.id}"
    render_hook(live_view, "select-formation", %{"sequence" => selected_event.id})
    assert_patch live_view, chapter_path

    assert has_element?(live_view, "#gesture-status", "Return to the live edge to contribute.")
    refute has_element?(live_view, "#gesture-cooldown-ring")
    refute has_element?(live_view, "#gesture-status", "Gesture controls return in")

    Process.sleep(1_100)
    render_patch(live_view, "/")

    assert has_element?(live_view, "#worldloom[data-mode='live']")
    assert has_element?(live_view, "#gesture-dock[aria-disabled='true']")

    document = live_view |> render() |> LazyHTML.from_fragment()

    [remaining_text] =
      document
      |> LazyHTML.query("#gesture-cooldown-ring")
      |> LazyHTML.attribute("data-seconds")

    remaining_seconds = String.to_integer(remaining_text)
    assert remaining_seconds in 1..29

    assert has_element?(
             live_view,
             "#gesture-status",
             "Gesture controls return in #{remaining_seconds} seconds."
           )

    render_patch(live_view, chapter_path)
    send(live_view.pid, :gesture_ready)

    assert eventually(fn ->
             has_element?(
               live_view,
               "#gesture-status",
               "Return to the live edge to contribute."
             ) and
               not has_element?(live_view, "#gesture-cooldown-ring") and
               not has_element?(live_view, "#gesture-status", "Gesture controls return in")
           end)
  end

  test "direct gesture boundary rejects malformed lane text", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    live_view
    |> form("#gesture-lane-form")
    |> render_submit(%{"gesture" => "tug", "lane" => "sideways"})

    assert has_element?(live_view, "#gesture-status", "Choose a valid gesture and lane")
    refute_push_event live_view, "worldloom:event", _rejected
    refute_push_event live_view, "worldloom:snapshot", _rejected_snapshot
  end

  test "renders the Living Fiber semantics and public source attribution", %{conn: conn} do
    {:ok, live_view, html} = live(conn, "/")

    assert has_element?(live_view, "#wordmark", "Worldloom")
    assert has_element?(live_view, "#utc-chapter", "UTC")
    assert has_element?(live_view, "#viewer-count")
    assert has_element?(live_view, "#archive-link")
    assert has_element?(live_view, "#about-link")
    assert has_element?(live_view, "#share-worldloom")
    assert has_element?(live_view, "#share-status[aria-live='polite']")
    assert has_element?(live_view, "#share-fallback-field[hidden][phx-update='ignore']")
    assert has_element?(live_view, "label[for='share-fallback']", "Permanent link")
    assert has_element?(live_view, "#share-fallback[type='url'][readonly]")
    assert has_element?(live_view, "#mobile-worldloom-menu a[href='/chapters']", "Archive")
    assert has_element?(live_view, "#mobile-worldloom-menu a[href='/about']", "About")
    assert has_element?(live_view, "#mobile-worldloom-menu button", "Share")
    assert has_element?(live_view, "#signal-legend [data-family='wikimedia']")
    assert has_element?(live_view, "#signal-legend [data-family='usgs']")
    assert has_element?(live_view, "#signal-legend [data-family='open_meteo']")
    assert has_element?(live_view, "#signal-legend [data-family='visitor']")
    assert has_element?(live_view, "#signal-legend[data-usgs-state='quiet']")
    assert has_element?(live_view, "#signal-legend[data-weather-state='stale']")
    assert has_element?(live_view, "#live-summary[aria-live='polite']")

    assert html =~
             "Worldloom needs JavaScript to draw the living fabric. Its public source, privacy contract, and data-source documentation remain available in the repository."

    {:ok, about_view, _html} = live(recycle(conn), "/about")

    assert has_element?(
             about_view,
             ".about-lede",
             "Worldloom is one living public record. Activity from across the world enters as fiber, tension, atmosphere, and light—then remains part of the same shared fabric."
           )

    assert has_element?(about_view, ".about-sections section", "Public change, given form")

    assert has_element?(
             about_view,
             ".about-sections section",
             "Shape the present, never rewrite the past"
           )

    assert has_element?(about_view, ".about-sections section", "The weave survives the room")
    assert has_element?(about_view, ".about-sections section", "No identity enters the artwork")

    assert has_element?(
             about_view,
             ".about-sections section",
             "The canvas is not the only way in"
           )

    assert has_element?(
             about_view,
             "#source-attribution a[href='https://stream.wikimedia.org/'][rel='noreferrer']",
             "Wikimedia"
           )

    assert has_element?(
             about_view,
             "#source-attribution a[href='https://earthquake.usgs.gov/'][rel='noreferrer']",
             "USGS"
           )

    assert has_element?(
             about_view,
             "#source-attribution a[href='https://open-meteo.com/'][rel='noreferrer']",
             "Open-Meteo"
           )

    assert has_element?(about_view, "#source-attribution h2", "Public sources")

    assert has_element?(
             about_view,
             ".about-technology",
             "Worldloom is built with Phoenix LiveView, OTP, PubSub, Presence, PostgreSQL, and a deterministic Canvas 2D renderer."
           )

    assert has_element?(
             about_view,
             ".about-technology a[href='https://github.com/romankhadka/worldloom'][rel='noreferrer']",
             "Read the public source"
           )
  end

  test "commits a gesture before its snapshot broadcast and exposes cooldown safely", %{
    conn: conn
  } do
    peer_id = System.unique_integer([:positive, :monotonic])

    peer_address =
      {127, rem(div(peer_id, 65_536), 256), rem(div(peer_id, 256), 256), rem(peer_id, 256)}

    conn =
      Plug.Test.put_peer_data(conn, %{address: peer_address, port: 40_000, ssl_cert: nil})

    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "gesture", %{"gesture" => "illuminate", "lane" => 0.72})

    assert_push_event live_view, "worldloom:gesture-accepted", %{"sequence" => sequence}

    assert_push_event live_view, "worldloom:snapshot", %{
      commit_watermark: ^sequence,
      window_end: nil
    }

    assert {:ok, stored_event} = Store.fetch(sequence)
    assert stored_event.kind == "illuminate"
    assert stored_event.source == "visitor"
    assert stored_event.lane == 0.72
    assert stored_event.payload["summary"] == "A visitor illuminated a thread"
    assert Enum.sort(Map.keys(stored_event.payload)) == ["summary", "visual"]
    assert Enum.sort(Map.keys(stored_event.payload["visual"])) == ["bend", "pulse", "spread"]
    refute Map.has_key?(stored_event.payload, "visitor_identity")
    refute Map.has_key?(stored_event.payload, "peer_address")
    refute_push_event live_view, "worldloom:event", _duplicate
    refute_push_event live_view, "worldloom:snapshot", _duplicate_snapshot

    render_hook(live_view, "gesture", %{"gesture" => "illuminate", "lane" => 0.72})

    document = live_view |> render() |> LazyHTML.from_fragment()

    [remaining_text] =
      document
      |> LazyHTML.query("#gesture-cooldown-ring")
      |> LazyHTML.attribute("data-seconds")

    remaining_seconds = String.to_integer(remaining_text)
    assert remaining_seconds in 1..30

    assert has_element?(
             live_view,
             "#gesture-status",
             "Try again in #{remaining_seconds} seconds"
           )

    assert has_element?(
             live_view,
             "#gesture-status",
             "Gesture controls return in #{remaining_seconds} seconds."
           )

    refute_push_event live_view, "worldloom:event", _rejected
    refute_push_event live_view, "worldloom:snapshot", _rejected_snapshot
  end

  test "rejects forged, panned-away, and historical gestures with safe text", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "gesture", %{"gesture" => "script", "lane" => "left"})
    assert has_element?(live_view, "#gesture-status", "Choose a valid gesture and lane")

    render_hook(live_view, "viewport-state", %{"at_live_edge" => false})
    assert has_element?(live_view, "#gesture-dock[aria-disabled='true']")
    assert has_element?(live_view, "#return-live")

    for gesture <- ["tug", "knot", "illuminate"] do
      assert has_element?(live_view, "#gesture-#{gesture}[disabled]")
    end

    render_hook(live_view, "gesture", %{"gesture" => "tug", "lane" => 0.5})
    assert has_element?(live_view, "#gesture-status", "Return to the live edge")

    [event] = seed_events(1, ~U[2026-08-03 14:00:00.000000Z])
    {:ok, chapter_view, _html} = live(recycle(conn), "/chapters/2026-08-03/#{event.id}")
    render_hook(chapter_view, "gesture", %{"gesture" => "tug", "lane" => 0.5})
    assert has_element?(chapter_view, "#gesture-status", "Return to the live edge")
  end

  test "resolves formation detail on the server and shares its generated permalink", %{conn: conn} do
    [event] = seed_events(1, ~U[2026-08-03 15:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "select-formation", %{
      "sequence" => event.id,
      "summary" => "forged summary",
      "source" => "forged source"
    })

    path = "/chapters/2026-08-03/#{event.id}"
    assert_patch live_view, path
    assert has_element?(live_view, "#signal-detail", "Public formation 1")
    refute render(live_view) =~ "forged summary"
    refute render(live_view) =~ event.external_id
    assert has_element?(live_view, "#share-link[readonly][value$='#{path}']")

    live_view |> element("#share-worldloom") |> render_click()
    assert_push_event live_view, "worldloom:copy-link", %{url: copied_url}
    assert String.ends_with?(copied_url, path)
  end

  test "dismisses trusted formation detail without changing its permalink", %{conn: conn} do
    [event] = seed_events(1, ~U[2026-08-03 15:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "select-formation", %{"sequence" => event.id})

    path = "/chapters/2026-08-03/#{event.id}"
    assert_patch live_view, path
    assert has_element?(live_view, "#worldloom[data-mode='chapter']")
    assert has_element?(live_view, "#signal-detail", "Public formation 1")

    live_view |> element("#signal-detail") |> render_keydown(%{"key" => "Escape"})

    refute has_element?(live_view, "#signal-detail")
    assert has_element?(live_view, "#worldloom[data-mode='chapter']")
    live_view |> element("#share-worldloom") |> render_click()
    assert_push_event live_view, "worldloom:copy-link", %{url: copied_url}
    assert String.ends_with?(copied_url, path)
  end

  test "accessible formation controls open the same trusted detail", %{conn: conn} do
    [event] = seed_events(1, ~U[2026-08-03 16:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    live_view
    |> element("#formation-#{event.id}")
    |> render_click()

    assert_patch live_view, "/chapters/2026-08-03/#{event.id}"
    assert has_element?(live_view, "#signal-detail", "Public formation 1")
  end

  defp seed_events(count, start_time \\ ~U[2026-08-03 12:00:00.000000Z]) do
    unique = System.unique_integer([:positive, :monotonic])

    source_events =
      Enum.map(1..count, fn index ->
        SourceEvent.new!(%{
          kind: :wikimedia,
          source: :wikimedia,
          external_id: "world-live-#{unique}-#{index}",
          occurred_at: DateTime.add(start_time, index - 1, :second),
          lane: 0.4,
          intensity: 0.6,
          payload: %{"summary" => "Public formation #{index}"}
        })
      end)

    assert {:ok, events} =
             Store.commit_external(source_events, %{
               source: "wikimedia",
               cursor: "world-live-cursor-#{unique}",
               etag: nil,
               last_successful_at: start_time,
               metadata: %{}
             })

    append_current_display(events)
    events
  end

  defp seed_visitor_events(count, start_time) do
    unique = System.unique_integer([:positive, :monotonic])

    events =
      Enum.map(1..count, fn index ->
        visitor =
          SourceEvent.new!(%{
            kind: :illuminate,
            source: :visitor,
            external_id: nil,
            occurred_at: DateTime.add(start_time, index - 1, :second),
            lane: 0.5,
            intensity: 0.6,
            payload: %{"summary" => "Visitor formation #{index}"}
          })

        assert {:ok, event} =
                 Store.commit_visitor(visitor, "world-live-visitor-#{unique}-#{index}")

        event
      end)

    append_current_display(events)
    events
  end

  defp seed_weather_event(occurred_at) do
    unique = System.unique_integer([:positive, :monotonic])

    weather =
      SourceEvent.new!(%{
        kind: :weather,
        source: :open_meteo,
        external_id: "world-live-weather-#{unique}",
        occurred_at: occurred_at,
        lane: 0.5,
        intensity: 0.6,
        payload: %{"summary" => "Weather formation #{unique}"}
      })

    assert {:ok, [event]} =
             Store.commit_external([weather], %{
               source: "open_meteo",
               cursor: "world-live-weather-cursor-#{unique}",
               etag: nil,
               last_successful_at: occurred_at,
               metadata: %{}
             })

    update_current_ambient(event)
    event
  end

  defp seed_earthquake_event(occurred_at) do
    unique = System.unique_integer([:positive, :monotonic])

    earthquake =
      SourceEvent.new!(%{
        kind: :earthquake,
        source: :usgs,
        external_id: "world-live-earthquake-#{unique}",
        occurred_at: occurred_at,
        lane: 0.3,
        intensity: 0.8,
        payload: %{"summary" => "Earthquake formation #{unique}"}
      })

    assert {:ok, [event]} =
             Store.commit_external([earthquake], %{
               source: "usgs",
               cursor: "world-live-earthquake-cursor-#{unique}",
               etag: nil,
               last_successful_at: occurred_at,
               metadata: %{}
             })

    append_current_display([event])
    event
  end

  defp seed_live_snapshot_fixture(window_end \\ ~U[2026-08-08 12:01:00Z]) do
    display_events = seed_events(2, DateTime.add(window_end, -10, :second))
    contextual_earthquake = seed_earthquake_event(DateTime.add(window_end, -90, :second))
    [contextual_visitor] = seed_visitor_events(1, DateTime.add(window_end, -80, :second))
    ambient = seed_weather_event(DateTime.add(window_end, 30, :second))

    snapshot = %LiveSnapshot{
      window_end: window_end,
      commit_watermark: Store.highest_sequence(),
      display_events: display_events,
      memory_events: [contextual_earthquake, contextual_visitor],
      ambient: ambient
    }

    put_current_snapshot(snapshot)
    snapshot
  end

  defp synthetic_live_snapshot_fixture do
    window_end = ~U[2026-08-08 12:01:00Z]

    %LiveSnapshot{
      window_end: window_end,
      commit_watermark: 906,
      display_events: [
        synthetic_event(901, "wikimedia", "wikimedia", DateTime.add(window_end, -10, :second)),
        synthetic_event(902, "wikimedia", "wikimedia", DateTime.add(window_end, -9, :second))
      ],
      memory_events: [
        synthetic_event(903, "earthquake", "usgs", DateTime.add(window_end, -90, :second)),
        synthetic_event(904, "illuminate", "visitor", DateTime.add(window_end, -80, :second))
      ],
      ambient:
        synthetic_event(905, "weather", "open_meteo", DateTime.add(window_end, 30, :second))
    }
  end

  defp synthetic_event(sequence, kind, source, occurred_at) do
    %Event{
      id: sequence,
      kind: kind,
      source: source,
      occurred_at: occurred_at,
      render_version: 1,
      render_seed: sequence,
      lane: 0.4,
      intensity: 0.6,
      payload: %{
        "summary" => "Synthetic #{kind} formation #{sequence}",
        "visual" => %{"bend" => 0.1, "pulse" => 0.2, "spread" => 0.3}
      }
    }
  end

  defp append_current_display(events) do
    snapshot = Coordinator.current_snapshot()
    candidates = snapshot.display_events ++ events

    window_end =
      candidates
      |> Enum.max_by(&{&1.occurred_at, &1.id})
      |> Map.fetch!(:occurred_at)
      |> DateTime.truncate(:second)

    display_events =
      candidates
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&(DateTime.diff(&1.occurred_at, window_end, :second) in -60..0))
      |> Enum.sort_by(&{&1.occurred_at, &1.id})

    commit_watermark =
      Enum.reduce(events, snapshot.commit_watermark, fn event, watermark ->
        max(event.id, watermark)
      end)

    put_current_snapshot(%{
      snapshot
      | window_end: window_end,
        commit_watermark: commit_watermark,
        display_events: display_events
    })
  end

  defp update_current_ambient(event) do
    snapshot = Coordinator.current_snapshot()

    put_current_snapshot(%{
      snapshot
      | commit_watermark: max(event.id, snapshot.commit_watermark),
        ambient: event
    })
  end

  defp put_current_snapshot(snapshot) do
    CoordinatorTestStore.put_snapshot(snapshot)

    :sys.replace_state(Coordinator, fn state ->
      %{state | snapshot: snapshot, highest_sequence: snapshot.commit_watermark}
    end)
  end

  defp encoded_snapshot(snapshot) do
    %{
      snapshot_version: snapshot.snapshot_version,
      window_end: snapshot.window_end && DateTime.to_iso8601(snapshot.window_end),
      commit_watermark: snapshot.commit_watermark,
      display_events: Enum.map(snapshot.display_events, &Instruction.from_event/1),
      memory_events: Enum.map(snapshot.memory_events, &Instruction.from_event/1),
      ambient: snapshot.ambient && Instruction.from_event(snapshot.ambient)
    }
  end

  defp source_sequence_pairs(events) do
    Enum.map(events, fn
      %{source: source, id: sequence} -> {source, sequence}
      %{"source" => source, "sequence" => sequence} -> {source, sequence}
    end)
  end

  defp accessible_sequence_ids(live_view) do
    live_view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#accessible-formations button")
    |> LazyHTML.attribute("id")
    |> Enum.map(fn "formation-" <> sequence -> String.to_integer(sequence) end)
  end

  defp live_assign(live_view, assign_name) do
    live_view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(assign_name)
  end

  defp allow_history_request(live_view) do
    :sys.replace_state(live_view.pid, fn state ->
      socket =
        state
        |> Map.fetch!(:socket)
        |> Map.update!(:assigns, &Map.put(&1, :history_requested_at, nil))

      Map.put(state, :socket, socket)
    end)
  end

  defp instruction_sequence_ids(instructions) do
    Enum.map(instructions, & &1["sequence"])
  end

  defp chapter_path(event) do
    "/chapters/#{Date.to_iso8601(DateTime.to_date(event.occurred_at))}/#{event.id}"
  end

  defp eventually(assertion, attempts \\ 20)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    if assertion.() do
      true
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp trace_route_calls(pid, route_change) do
    traced_functions = [
      {Phoenix.PubSub, :subscribe, 2},
      {Coordinator, :current_snapshot, 0}
    ]

    Enum.each(traced_functions, &:erlang.trace_pattern(&1, true, []))
    :erlang.trace(pid, true, [:call, {:tracer, self()}])

    try do
      route_change.()

      Enum.map(traced_functions, fn _function ->
        receive do
          {:trace, ^pid, :call, {module, function, arguments}} ->
            {module, function, arguments}
        after
          1_000 -> flunk("expected traced live-route call")
        end
      end)
    after
      :erlang.trace(pid, false, [:call])
      Enum.each(traced_functions, &:erlang.trace_pattern(&1, false, []))
    end
  end

  defp count_function_calls(traced_function, load_route) do
    :erlang.trace_pattern(traced_function, true, [:call_count])

    try do
      route = load_route.()
      {:call_count, latest_call_count} = :erlang.trace_info(traced_function, :call_count)
      {route, latest_call_count}
    after
      :erlang.trace_pattern(traced_function, false, [:call_count])
    end
  end
end
