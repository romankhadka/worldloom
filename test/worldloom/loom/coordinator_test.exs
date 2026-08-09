defmodule Worldloom.Loom.CoordinatorTest do
  use Worldloom.DataCase

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.CoordinatorTestStore
  alias Worldloom.Loom.Event
  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Loom.LiveSnapshot
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store

  setup context do
    if context[:committed_storage] do
      {:ok, independent_repo} =
        Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 4)

      Process.unlink(independent_repo)
      Repo.put_dynamic_repo(independent_repo)
      storage_token = "coordinator-test-#{System.unique_integer([:positive, :monotonic])}"
      Process.put(:coordinator_test_storage_token, storage_token)

      on_exit(fn ->
        if Process.alive?(independent_repo) do
          Repo.put_dynamic_repo(independent_repo)

          Event
          |> where(
            [event],
            like(fragment("?->>'summary'", event.payload), ^"%#{storage_token}%")
          )
          |> Repo.delete_all()

          FeedCheckpoint
          |> where(
            [checkpoint],
            fragment("?->>'coordinator_test_storage_token'", checkpoint.metadata) ==
              ^storage_token
          )
          |> Repo.delete_all()

          Supervisor.stop(independent_repo)
        end
      end)

      {:ok, independent_repo: independent_repo, storage_token: storage_token}
    else
      :ok
    end
  end

  test "initializes from one authoritative live snapshot" do
    authoritative_snapshot = snapshot(73, ~U[2026-08-08 12:01:00Z], [stored_event(12)])

    {coordinator, _topic} =
      start_test_coordinator(
        snapshots: [authoritative_snapshot],
        highest_sequence: 999
      )

    assert CoordinatorTestStore.calls() == [{:live_snapshot, nil}]
    assert Coordinator.current_snapshot(coordinator) == authoritative_snapshot
    assert Coordinator.highest_sequence(coordinator) == authoritative_snapshot.commit_watermark
    assert CoordinatorTestStore.calls() == [{:live_snapshot, nil}]
  end

  test "an explicit empty bootstrap avoids storage until the first durable commit" do
    inserted_event = stored_event(41)
    authoritative_snapshot = snapshot(41, ~U[2026-08-08 12:01:00Z], [inserted_event])

    start_supervised!(
      {CoordinatorTestStore,
       external_results: [{:ok, [inserted_event]}], snapshots: [authoritative_snapshot]}
    )

    {coordinator, _topic} =
      start_coordinator(store: CoordinatorTestStore, bootstrap: :empty)

    assert Coordinator.current_snapshot(coordinator) == CoordinatorTestStore.empty_snapshot()
    assert Coordinator.highest_sequence(coordinator) == 0
    assert CoordinatorTestStore.calls() == []

    assert {:ok, [^inserted_event]} =
             Coordinator.commit_external(
               coordinator,
               [source_event(41)],
               checkpoint("cursor-41")
             )

    assert Coordinator.current_snapshot(coordinator) == authoritative_snapshot
    assert Coordinator.highest_sequence(coordinator) == 41
    assert {:live_snapshot, nil} in CoordinatorTestStore.calls()
  end

  test "rejects an unknown bootstrap strategy before starting" do
    assert_raise ArgumentError, ~r/bootstrap must be :store or :empty/, fn ->
      Coordinator.start_link(name: nil, bootstrap: :unknown)
    end
  end

  @tag :committed_storage
  test "serializes concurrent commits and broadcasts snapshots in watermark order", %{
    independent_repo: independent_repo,
    storage_token: storage_token
  } do
    {coordinator, topic} = start_database_coordinator(independent_repo)

    results =
      1..10
      |> Task.async_stream(
        fn index ->
          Coordinator.commit_external(
            coordinator,
            [source_event(index, nil, storage_token)],
            checkpoint("cursor-#{index}", storage_token)
          )
        end,
        ordered: false,
        max_concurrency: 10
      )
      |> Enum.map(fn {:ok, {:ok, [event]}} -> event end)

    snapshots = receive_snapshots(topic, 10)
    watermarks = Enum.map(snapshots, & &1.commit_watermark)

    assert watermarks == Enum.sort(watermarks)
    assert Enum.sort(watermarks) == results |> Enum.map(& &1.id) |> Enum.sort()
    assert Coordinator.highest_sequence(coordinator) == List.last(watermarks)
    assert Coordinator.current_snapshot(coordinator) == List.last(snapshots)
    refute_receive {:loom_snapshot, _snapshot}, 50
    refute_receive {:loom_event, _instruction}, 50
  end

  test "projects only after a successful non-empty durable external commit" do
    initial_snapshot = snapshot(40, ~U[2026-08-08 12:00:00Z], [stored_event(4)])
    committed_event = stored_event(41)
    projected_snapshot = snapshot(91, ~U[2026-08-08 12:01:00Z], [stored_event(9)])
    source = source_event(41)
    durable_checkpoint = checkpoint("cursor-41")

    {coordinator, _topic} =
      start_test_coordinator(
        snapshots: [initial_snapshot, projected_snapshot],
        external_results: [{:ok, [committed_event]}]
      )

    assert {:ok, [^committed_event]} =
             Coordinator.commit_external(coordinator, [source], durable_checkpoint)

    assert CoordinatorTestStore.calls() == [
             {:live_snapshot, nil},
             {:commit_external, [source], durable_checkpoint},
             {:commit_external_returned, {:ok, [committed_event]}},
             {:live_snapshot, initial_snapshot.window_end}
           ]

    sequence = projected_snapshot.commit_watermark
    assert_receive {:loom_snapshot, %LiveSnapshot{commit_watermark: ^sequence} = broadcast}, 500
    assert broadcast == projected_snapshot
    refute_receive {:loom_snapshot, _snapshot}, 50
    refute_receive {:loom_event, _instruction}, 50
    assert Coordinator.current_snapshot(coordinator) == projected_snapshot
    assert Coordinator.highest_sequence(coordinator) == sequence
  end

  @tag :committed_storage
  test "a separate committed connection sees the durable row before the snapshot is received", %{
    independent_repo: independent_repo,
    storage_token: storage_token
  } do
    {coordinator, topic} = start_database_coordinator(independent_repo)

    assert {:ok, [event]} =
             Coordinator.commit_external(
               coordinator,
               [source_event(1, nil, storage_token)],
               checkpoint("cursor-1", storage_token)
             )

    visible_event =
      Task.async(fn ->
        Repo.put_dynamic_repo(independent_repo)
        Store.fetch(event.id)
      end)
      |> Task.await()

    assert visible_event == {:ok, event}
    sequence = event.id
    assert_receive {:loom_snapshot, %LiveSnapshot{commit_watermark: ^sequence}}, 500
    refute_receive {:loom_event, _instruction}, 50
    assert Coordinator.current_snapshot(coordinator).commit_watermark == sequence
    assert topic != Coordinator.topic()
  end

  test "a rolled back commit produces no broadcast or projection" do
    initial_snapshot = snapshot(12, ~U[2026-08-08 12:00:00Z], [stored_event(12)])
    invalid_event = %{source_event(1) | intensity: 2.0}
    invalid_checkpoint = checkpoint("cursor-invalid")

    {coordinator, _topic} =
      start_test_coordinator(
        snapshots: [initial_snapshot],
        external_results: [{:error, {:invalid_event, {:intensity, :out_of_bounds}}}]
      )

    assert {:error, {:invalid_event, {:intensity, :out_of_bounds}}} =
             Coordinator.commit_external(coordinator, [invalid_event], invalid_checkpoint)

    assert CoordinatorTestStore.calls() == [
             {:live_snapshot, nil},
             {:commit_external, [invalid_event], invalid_checkpoint},
             {:commit_external_returned, {:error, {:invalid_event, {:intensity, :out_of_bounds}}}}
           ]

    refute_receive {:loom_snapshot, _snapshot}, 50
    refute_receive {:loom_event, _instruction}, 50
    assert Coordinator.current_snapshot(coordinator) == initial_snapshot
    assert Coordinator.highest_sequence(coordinator) == initial_snapshot.commit_watermark
  end

  test "a duplicate checkpoint-only commit is silent and preserves the snapshot" do
    initial_snapshot = snapshot(24, ~U[2026-08-08 12:00:00Z], [stored_event(24)])
    duplicate = source_event(24)
    advanced_checkpoint = checkpoint("cursor-25")

    {coordinator, _topic} =
      start_test_coordinator(
        snapshots: [initial_snapshot],
        external_results: [{:ok, []}]
      )

    assert {:ok, []} =
             Coordinator.commit_external(coordinator, [duplicate], advanced_checkpoint)

    assert CoordinatorTestStore.calls() == [
             {:live_snapshot, nil},
             {:commit_external, [duplicate], advanced_checkpoint},
             {:commit_external_returned, {:ok, []}}
           ]

    refute_receive {:loom_snapshot, _snapshot}, 50
    refute_receive {:loom_event, _instruction}, 50
    assert Coordinator.current_snapshot(coordinator) == initial_snapshot
    assert Coordinator.highest_sequence(coordinator) == initial_snapshot.commit_watermark
  end

  test "a late recovery row advances the watermark without moving the window" do
    window_end = ~U[2026-08-08 12:05:00Z]
    initial_snapshot = snapshot(30, window_end, [stored_event(30, window_end)])
    late_event = stored_event(31, ~U[2026-08-08 11:59:00Z])
    recovered_snapshot = snapshot(31, window_end, [stored_event(30, window_end)])
    source = source_event(31, late_event.occurred_at)
    recovery_checkpoint = checkpoint("cursor-recovery")

    {coordinator, _topic} =
      start_test_coordinator(
        snapshots: [initial_snapshot, recovered_snapshot],
        external_results: [{:ok, [late_event]}]
      )

    assert {:ok, [^late_event]} =
             Coordinator.commit_external(coordinator, [source], recovery_checkpoint)

    assert CoordinatorTestStore.calls() == [
             {:live_snapshot, nil},
             {:commit_external, [source], recovery_checkpoint},
             {:commit_external_returned, {:ok, [late_event]}},
             {:live_snapshot, window_end}
           ]

    sequence = recovered_snapshot.commit_watermark
    assert_receive {:loom_snapshot, %LiveSnapshot{commit_watermark: ^sequence} = broadcast}, 500
    assert broadcast == recovered_snapshot
    assert broadcast.window_end == initial_snapshot.window_end
    refute_receive {:loom_snapshot, _snapshot}, 50
    refute_receive {:loom_event, _instruction}, 50
    assert Coordinator.current_snapshot(coordinator) == recovered_snapshot
    assert Coordinator.highest_sequence(coordinator) == sequence
  end

  test "visitor commits project and broadcast one authoritative snapshot" do
    initial_snapshot = snapshot(50, ~U[2026-08-08 12:00:00Z], [stored_event(50)])
    visitor = visitor_source_event()
    committed_event = stored_event(51, visitor.occurred_at, "visitor", "knot")
    projected_snapshot = snapshot(54, ~U[2026-08-08 12:00:00Z], [stored_event(50)])

    {coordinator, _topic} =
      start_test_coordinator(
        snapshots: [initial_snapshot, projected_snapshot],
        visitor_results: [{:ok, committed_event}]
      )

    assert {:ok, ^committed_event} =
             Coordinator.commit_visitor(coordinator, visitor, "request-nonce-knot")

    assert CoordinatorTestStore.calls() == [
             {:live_snapshot, nil},
             {:commit_visitor, visitor, "request-nonce-knot"},
             {:commit_visitor_returned, {:ok, committed_event}},
             {:live_snapshot, initial_snapshot.window_end}
           ]

    sequence = projected_snapshot.commit_watermark
    assert_receive {:loom_snapshot, %LiveSnapshot{commit_watermark: ^sequence} = broadcast}, 500
    assert broadcast == projected_snapshot
    refute_receive {:loom_snapshot, _snapshot}, 50
    refute_receive {:loom_event, _instruction}, 50
    assert Coordinator.current_snapshot(coordinator) == projected_snapshot
    assert Coordinator.highest_sequence(coordinator) == sequence
  end

  @tag :committed_storage
  test "visitor events persist before their snapshot is broadcast", %{
    independent_repo: independent_repo
  } do
    {coordinator, _topic} = start_database_coordinator(independent_repo)
    visitor = visitor_source_event()

    assert {:ok, event} =
             Coordinator.commit_visitor(coordinator, visitor, "request-nonce-knot")

    assert {:ok, ^event} = Store.fetch(event.id)

    sequence = event.id
    assert_receive {:loom_snapshot, %LiveSnapshot{commit_watermark: ^sequence}}, 500
    refute_receive {:loom_event, _instruction}, 50
    assert Coordinator.current_snapshot(coordinator).commit_watermark == sequence
  end

  @tag :committed_storage
  test "highest sequence and snapshot recover from durable storage after restart", %{
    independent_repo: independent_repo
  } do
    topic = unique_topic()
    Phoenix.PubSub.subscribe(Worldloom.PubSub, topic)
    start_database_store(independent_repo)

    {:ok, coordinator} =
      Coordinator.start_link(name: nil, topic: topic, store: CoordinatorTestStore)

    assert {:ok, [event]} =
             Coordinator.commit_external(
               coordinator,
               [source_event(1)],
               checkpoint("cursor-1")
             )

    assert Coordinator.highest_sequence(coordinator) == event.id
    assert Coordinator.current_snapshot(coordinator).commit_watermark == event.id
    GenServer.stop(coordinator)

    {:ok, restarted} =
      Coordinator.start_link(name: nil, topic: topic, store: CoordinatorTestStore)

    on_exit(fn -> Process.exit(restarted, :shutdown) end)

    assert Coordinator.highest_sequence(restarted) == event.id
    assert Coordinator.current_snapshot(restarted).commit_watermark == event.id
  end

  @tag :committed_storage
  test "emits privacy-safe commit telemetry", %{independent_repo: independent_repo} do
    {coordinator, _topic} = start_database_coordinator(independent_repo)
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:worldloom, :loom, :commit],
        fn event_name, measurements, metadata, test_process ->
          send(test_process, {:telemetry, event_name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, [_event]} =
             Coordinator.commit_external(
               coordinator,
               [source_event(1)],
               checkpoint("cursor-1")
             )

    assert_receive {:telemetry, [:worldloom, :loom, :commit], measurements,
                    %{kind: :external, status: :ok}},
                   500

    assert measurements.count == 1
    assert measurements.duration >= 0
    assert is_integer(measurements.highest_sequence)
  end

  defp start_coordinator(options) do
    topic = unique_topic()
    Phoenix.PubSub.subscribe(Worldloom.PubSub, topic)

    {:ok, coordinator} =
      Coordinator.start_link(
        name: nil,
        topic: topic,
        store: Keyword.get(options, :store, Store),
        bootstrap: Keyword.get(options, :bootstrap, :store)
      )

    on_exit(fn -> Process.exit(coordinator, :shutdown) end)
    {coordinator, topic}
  end

  defp start_test_coordinator(options) do
    start_supervised!({CoordinatorTestStore, options})
    start_coordinator(store: CoordinatorTestStore)
  end

  defp start_database_coordinator(independent_repo) do
    start_database_store(independent_repo)
    start_coordinator(store: CoordinatorTestStore)
  end

  defp start_database_store(independent_repo) do
    start_supervised!({CoordinatorTestStore, delegate: Store, repo: independent_repo})
  end

  defp unique_topic, do: "loom:test:#{System.unique_integer([:positive, :monotonic])}"

  defp receive_snapshots(topic, count) do
    assert is_binary(topic)

    Enum.map(1..count, fn _index ->
      assert_receive {:loom_snapshot, %LiveSnapshot{} = snapshot}, 1_000
      snapshot
    end)
  end

  defp snapshot(commit_watermark, window_end, display_events) do
    %LiveSnapshot{
      window_end: window_end,
      commit_watermark: commit_watermark,
      display_events: display_events,
      memory_events: [],
      ambient: nil
    }
  end

  defp stored_event(
         id,
         occurred_at \\ ~U[2026-08-08 12:00:00Z],
         source \\ "wikimedia",
         kind \\ "wikimedia"
       ) do
    %Event{
      id: id,
      kind: kind,
      source: source,
      external_id: if(source == "visitor", do: nil, else: "stored-event-#{id}"),
      occurred_at: occurred_at,
      render_version: 1,
      render_seed: id,
      lane: 0.4,
      intensity: 0.6,
      payload: %{
        "summary" => "Stored event #{id}",
        "visual" => %{"spread" => 0.4, "bend" => 0.0, "pulse" => 0.6}
      }
    }
  end

  defp source_event(
         index,
         occurred_at \\ nil,
         storage_token \\ Process.get(:coordinator_test_storage_token)
       ) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: external_id("coordinator-revision-#{index}", storage_token),
      occurred_at: occurred_at || DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
      lane: 0.4,
      intensity: 0.6,
      payload:
        event_payload(
          %{"summary" => "Coordinator revision #{index} entered the weave"},
          storage_token
        )
    })
  end

  defp visitor_source_event(storage_token \\ Process.get(:coordinator_test_storage_token)) do
    SourceEvent.new!(%{
      kind: :knot,
      source: :visitor,
      external_id: nil,
      occurred_at: ~U[2026-08-03 12:00:00.000000Z],
      lane: 0.5,
      intensity: 0.6,
      payload:
        event_payload(
          %{"summary" => "A visitor tied a knot in the weave"},
          storage_token
        )
    })
  end

  defp checkpoint(cursor, storage_token \\ Process.get(:coordinator_test_storage_token)) do
    %{
      source: "wikimedia",
      cursor: cursor,
      etag: nil,
      last_successful_at: ~U[2026-08-03 12:01:00.000000Z],
      metadata: checkpoint_metadata(storage_token)
    }
  end

  defp external_id(base, nil), do: base
  defp external_id(base, storage_token), do: "#{storage_token}-#{base}"

  defp event_payload(payload, nil), do: payload

  defp event_payload(%{"summary" => summary} = payload, storage_token) do
    Map.put(payload, "summary", "#{summary} [#{storage_token}]")
  end

  defp checkpoint_metadata(nil), do: %{}

  defp checkpoint_metadata(storage_token) do
    %{"coordinator_test_storage_token" => storage_token}
  end
end
