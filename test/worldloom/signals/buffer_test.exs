defmodule Worldloom.Signals.BufferTest do
  use Worldloom.DataCase

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.CoordinatorTestStore
  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.HealthRegistry

  defmodule RejectingMerger do
    def merge(_events), do: raise("checkpoint-only entries must never enter Merger")
  end

  defmodule NonCompactingMerger do
    def merge(_events), do: {:error, :unsupported_source}
  end

  defmodule FailingCoordinator do
    use GenServer

    def start_link(test_process), do: GenServer.start_link(__MODULE__, test_process)

    @impl true
    def init(test_process), do: {:ok, {test_process, 0}}

    @impl true
    def handle_call({:external, [event], checkpoint}, _from, {test_process, call_count}) do
      send(test_process, {:coordinator_commit, event.external_id, checkpoint})

      reply = if call_count < 4, do: {:error, :database_down}, else: {:ok, [event]}
      {:reply, reply, {test_process, call_count + 1}}
    end
  end

  defmodule ScriptedCoordinator do
    use GenServer

    @source_by_checkpoint %{
      "wikimedia" => :wikimedia,
      "usgs" => :usgs,
      "open_meteo" => :open_meteo,
      "bluesky" => :bluesky,
      "ripe_ris" => :ripe_ris,
      "solana" => :solana,
      "drand" => :drand
    }

    def start_link(test_process, failures \\ %{}) do
      GenServer.start_link(__MODULE__, {test_process, failures})
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:external, events, checkpoint}, _from, {test_process, failures}) do
      source = source(events, checkpoint)
      external_ids = Enum.map(events, & &1.external_id)
      send(test_process, {:coordinator_commit, source, external_ids, checkpoint})

      {reply, remaining_failures} = next_reply(source, events, failures)
      {:reply, reply, {test_process, remaining_failures}}
    end

    defp source([event | _events], _checkpoint), do: event.source

    defp source([], checkpoint) do
      Map.fetch!(@source_by_checkpoint, checkpoint[:source] || checkpoint["source"])
    end

    defp next_reply(source, events, failures) do
      case Map.get(failures, source, 0) do
        :always ->
          {{:error, :database_down}, failures}

        failures_left when failures_left > 0 ->
          {{:error, :database_down}, Map.put(failures, source, failures_left - 1)}

        _no_failures ->
          {{:ok, events}, failures}
      end
    end
  end

  test "rotates ready source partitions while a failed source waits to retry" do
    {:ok, coordinator} = ScriptedCoordinator.start_link(self(), %{wikimedia: 1})
    {buffer, _coordinator} = start_buffer(coordinator: coordinator)

    submissions = [
      start_submission(
        buffer,
        [signal_event(:wikimedia, 1), signal_event(:wikimedia, 2)],
        checkpoint(:wikimedia, "wikimedia-2"),
        2
      ),
      start_submission(
        buffer,
        [signal_event(:bluesky, 1)],
        checkpoint(:bluesky, "bluesky-1"),
        3
      ),
      start_submission(
        buffer,
        [signal_event(:ripe_ris, 1)],
        checkpoint(:ripe_ris, "ripe-1"),
        4
      ),
      start_submission(
        buffer,
        [signal_event(:drand, 1)],
        checkpoint(:drand, "1"),
        5
      ),
      start_submission(
        buffer,
        [signal_event(:usgs, 1)],
        checkpoint(:usgs, "usgs-1"),
        6
      )
    ]

    Enum.each(1..7, fn _drain -> fire_timer(buffer, 250) end)

    attempts = Enum.map(1..7, fn _attempt -> receive_commit() end)

    assert attempts == [
             {:wikimedia, ["wikimedia-1"]},
             {:bluesky, ["bluesky-1"]},
             {:ripe_ris, ["ripe_ris-1"]},
             {:drand, ["drand-1"]},
             {:usgs, ["usgs-1"]},
             {:wikimedia, ["wikimedia-1"]},
             {:wikimedia, ["wikimedia-2"]}
           ]

    Enum.each(submissions, &assert(Task.await(&1) == :ok))
    assert Buffer.depth(buffer) == 0
  end

  test "exhausting one partition fails only its waiters and never blocks another source" do
    {:ok, coordinator} = ScriptedCoordinator.start_link(self(), %{wikimedia: :always})
    {buffer, _coordinator} = start_buffer(coordinator: coordinator)

    wikimedia =
      start_submission(
        buffer,
        [signal_event(:wikimedia, 1)],
        checkpoint(:wikimedia, "wikimedia-1"),
        1
      )

    bluesky =
      start_submission(
        buffer,
        [signal_event(:bluesky, 1)],
        checkpoint(:bluesky, "bluesky-1"),
        2
      )

    fire_timer(buffer, 250)
    fire_timer(buffer, 250)
    assert Task.await(bluesky) == :ok
    assert Task.yield(wikimedia, 0) == nil

    fire_timer(buffer, 250)
    fire_timer(buffer, 1_000)
    fire_timer(buffer, 5_000)

    assert Task.await(wikimedia) == {:error, :persistence_unavailable}
    assert Buffer.depth(buffer) == 0
  end

  test "bounds drand at twenty ordered rounds without invoking a reducer" do
    {:ok, coordinator} = ScriptedCoordinator.start_link(self())
    {buffer, _coordinator} = start_buffer(coordinator: coordinator, merger: RejectingMerger)

    assert Buffer.submit(
             buffer,
             Enum.map(1..21, &signal_event(:drand, &1)),
             checkpoint(:drand, "21")
           ) == {:error, :capacity}

    assert Buffer.depth(buffer) == 0
    rounds = Enum.map(1..20, &signal_event(:drand, &1))

    submission =
      start_submission(buffer, rounds, checkpoint(:drand, "20"), 20)

    Enum.each(1..20, fn _drain -> fire_timer(buffer, 250) end)

    committed_rounds =
      Enum.map(1..20, fn _round ->
        assert_receive {:coordinator_commit, :drand, [external_id], _checkpoint}, 500
        external_id
      end)

    assert committed_rounds == Enum.map(1..20, &"drand-#{&1}")
    assert Task.await(submission) == :ok
    assert Buffer.depth(buffer) == 0
  end

  test "bounds total depth atomically when no source-local run can compact" do
    registry = start_health_registry()
    {:ok, coordinator} = ScriptedCoordinator.start_link(self())

    {buffer, _coordinator} =
      start_buffer(
        coordinator: coordinator,
        health_registry: registry,
        merger: NonCompactingMerger
      )

    submissions = [
      start_submission(
        buffer,
        Enum.map(1..16, &signal_event(:bluesky, &1)),
        checkpoint(:bluesky, "16"),
        16
      ),
      start_submission(
        buffer,
        Enum.map(1..16, &signal_event(:ripe_ris, &1)),
        checkpoint(:ripe_ris, "16"),
        32
      ),
      start_submission(
        buffer,
        Enum.map(1..16, &signal_event(:solana, &1)),
        checkpoint(:solana, "16"),
        48
      ),
      start_submission(
        buffer,
        Enum.map(1..16, &signal_event(:drand, &1)),
        checkpoint(:drand, "16"),
        64
      )
    ]

    assert Buffer.submit(
             buffer,
             [signal_event(:usgs, 1)],
             checkpoint(:usgs, "1")
           ) == {:error, :capacity}

    state = :sys.get_state(buffer)
    assert state.depth == 64
    assert state.partitions |> Map.fetch!(:bluesky) |> :queue.len() == 16
    assert state.partitions |> Map.fetch!(:ripe_ris) |> :queue.len() == 16
    assert state.partitions |> Map.fetch!(:solana) |> :queue.len() == 16
    assert state.partitions |> Map.fetch!(:drand) |> :queue.len() == 16
    refute Map.has_key?(state.partitions, :usgs)
    assert HealthRegistry.current(registry).usgs.drops == 1
    assert HealthRegistry.current(registry).usgs.last_reason == :capacity

    Enum.each(1..64, fn _drain -> fire_timer(buffer, 250) end)
    Enum.each(submissions, &assert(Task.await(&1) == :ok))
  end

  test "source-local compaction retains every waiter and isolates retry state" do
    registry = start_health_registry()
    {:ok, coordinator} = ScriptedCoordinator.start_link(self(), %{wikimedia: 1})

    {buffer, _coordinator} =
      start_buffer(coordinator: coordinator, health_registry: registry)

    wikimedia_submissions =
      Enum.map(1..17, fn index ->
        expected_depth = if index == 17, do: 1, else: index

        start_submission(
          buffer,
          [signal_event(:wikimedia, index)],
          checkpoint(:wikimedia, Integer.to_string(index)),
          expected_depth
        )
      end)

    bluesky =
      start_submission(
        buffer,
        [signal_event(:bluesky, 1)],
        checkpoint(:bluesky, "1"),
        2
      )

    state = :sys.get_state(buffer)
    assert state.partitions |> Map.fetch!(:wikimedia) |> :queue.len() == 1
    assert state.partitions |> Map.fetch!(:bluesky) |> :queue.len() == 1

    fire_timer(buffer, 250)
    assert receive_commit() |> elem(0) == :wikimedia
    Enum.each(wikimedia_submissions, &assert(Task.yield(&1, 0) == nil))

    fire_timer(buffer, 250)
    assert receive_commit() == {:bluesky, ["bluesky-1"]}
    assert Task.await(bluesky) == :ok
    Enum.each(wikimedia_submissions, &assert(Task.yield(&1, 0) == nil))

    fire_timer(buffer, 250)
    assert receive_commit() |> elem(0) == :wikimedia
    Enum.each(wikimedia_submissions, &assert(Task.await(&1) == :ok))

    observation = HealthRegistry.current(registry).wikimedia
    assert observation.merges == 16
    assert observation.retries == 1
  end

  test "checkpoint-only pressure coalesces without entering a reducer" do
    {buffer, _coordinator} = start_buffer(merger: RejectingMerger)

    submissions =
      Enum.map(1..17, fn index ->
        expected_depth = if index == 17, do: 1, else: index

        start_submission(
          buffer,
          [],
          checkpoint(:wikimedia, "checkpoint-#{index}"),
          expected_depth
        )
      end)

    fire_timer(buffer, 250)
    Enum.each(submissions, &assert(Task.await(&1) == :ok))
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "checkpoint-17"
    assert Buffer.depth(buffer) == 0
  end

  test "a new ready source preempts a later retry timer and stale timers cannot double-drain" do
    {:ok, coordinator} = ScriptedCoordinator.start_link(self(), %{wikimedia: :always})
    {buffer, _coordinator} = start_buffer(coordinator: coordinator)

    wikimedia =
      start_submission(
        buffer,
        [signal_event(:wikimedia, 1)],
        checkpoint(:wikimedia, "1"),
        1
      )

    fire_timer(buffer, 250)
    assert receive_commit() == {:wikimedia, ["wikimedia-1"]}
    fire_timer(buffer, 250)
    assert receive_commit() == {:wikimedia, ["wikimedia-1"]}

    bluesky =
      start_submission(
        buffer,
        [signal_event(:bluesky, 1)],
        checkpoint(:bluesky, "1"),
        2
      )

    fire_timer(buffer, 250)
    assert receive_commit() == {:bluesky, ["bluesky-1"]}
    assert Task.await(bluesky) == :ok

    assert_receive {:timer_scheduled, ^buffer, stale_timer, 1_000}, 500
    send(buffer, stale_timer)
    :sys.get_state(buffer)
    refute_receive {:coordinator_commit, _source, _external_ids, _checkpoint}, 50

    fire_timer(buffer, 750)
    assert receive_commit() == {:wikimedia, ["wikimedia-1"]}
    fire_timer(buffer, 5_000)
    assert receive_commit() == {:wikimedia, ["wikimedia-1"]}
    assert Task.await(wikimedia) == {:error, :persistence_unavailable}
  end

  test "pressure never compacts a retrying head with later unattempted work" do
    registry = start_health_registry()
    {:ok, coordinator} = ScriptedCoordinator.start_link(self(), %{wikimedia: :always})

    {buffer, _coordinator} =
      start_buffer(coordinator: coordinator, health_registry: registry)

    retrying =
      start_submission(
        buffer,
        [signal_event(:wikimedia, 1)],
        checkpoint(:wikimedia, "1"),
        1
      )

    fire_timer(buffer, 250)
    assert receive_commit() == {:wikimedia, ["wikimedia-1"]}

    later =
      start_submission(
        buffer,
        Enum.map(2..17, &signal_event(:wikimedia, &1)),
        checkpoint(:wikimedia, "17"),
        2
      )

    entries =
      buffer
      |> :sys.get_state()
      |> Map.fetch!(:partitions)
      |> Map.fetch!(:wikimedia)
      |> :queue.to_list()

    assert [%{attempts: 1, events: [retrying_event]}, %{attempts: 0, events: [merged_event]}] =
             entries

    assert retrying_event.external_id == "wikimedia-1"
    assert merged_event.external_id != retrying_event.external_id
    assert HealthRegistry.current(registry).wikimedia.merges == 15

    fire_timer(buffer, 250)
    assert receive_commit() == {:wikimedia, ["wikimedia-1"]}
    fire_timer(buffer, 1_000)
    assert receive_commit() == {:wikimedia, ["wikimedia-1"]}
    fire_timer(buffer, 5_000)
    assert receive_commit() == {:wikimedia, ["wikimedia-1"]}

    assert Task.await(retrying) == {:error, :persistence_unavailable}
    assert Task.await(later) == {:error, :persistence_unavailable}
  end

  test "drains at most one event every 250 ms and replies only after the checkpoint-bearing event" do
    {buffer, _coordinator} = start_buffer()

    submission =
      Task.async(fn ->
        Buffer.submit(buffer, Enum.map(1..3, &source_event/1), checkpoint("cursor-3"))
      end)

    fire_timer(buffer, 250)
    assert length(Store.latest()) == 1
    assert Repo.get(FeedCheckpoint, "wikimedia") == nil
    assert Task.yield(submission, 0) == nil

    fire_timer(buffer, 250)
    assert length(Store.latest()) == 2
    assert Repo.get(FeedCheckpoint, "wikimedia") == nil
    assert Task.yield(submission, 0) == nil

    fire_timer(buffer, 250)
    assert Task.await(submission) == :ok
    assert length(Store.latest()) == 3
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "cursor-3"
    assert Buffer.depth(buffer) == 0
  end

  test "queue depth never exceeds sixteen and same-source overflow is merged" do
    {buffer, _coordinator} = start_buffer()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:worldloom, :signals, :buffer, :depth],
        fn _event_name, measurements, metadata, test_process ->
          send(test_process, {:buffer_depth, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    events = Enum.map(1..40, &wikimedia_bucket/1)
    submission = Task.async(fn -> Buffer.submit(buffer, events, checkpoint("cursor-40")) end)

    assert_receive {:timer_scheduled, ^buffer, {:drain, _token}, 250}, 500
    assert Buffer.depth(buffer) <= 16

    send(buffer, :drain)
    :sys.get_state(buffer)
    drain_until_complete(buffer, submission)

    persisted = Store.latest()
    assert length(persisted) <= 16
    assert Enum.sum(Enum.map(persisted, & &1.payload["count"])) == 40
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "cursor-40"
    assert_receive {:buffer_depth, %{depth: 0, source_depth: 0}, %{source: :wikimedia}}, 500
  end

  test "empty successful submissions enqueue one silent checkpoint-only commit" do
    {buffer, coordinator} = start_buffer(merger: RejectingMerger)
    Phoenix.PubSub.subscribe(Worldloom.PubSub, Coordinator.topic())

    submission = Task.async(fn -> Buffer.submit(buffer, [], checkpoint("empty-cursor")) end)

    assert_receive {:timer_scheduled, ^buffer, {:drain, _token}, 250}, 500
    assert Buffer.depth(buffer) == 1
    assert Task.yield(submission, 0) == nil

    send(buffer, :drain)
    assert Task.await(submission) == :ok
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "empty-cursor"
    assert Buffer.depth(buffer) == 0
    assert Coordinator.current_snapshot(coordinator).commit_watermark == Store.highest_sequence()
    refute_receive {:loom_snapshot, _snapshot}, 50
    refute_receive {:loom_event, _instruction}, 50
  end

  test "empty submissions reject missing, visitor, and unknown checkpoint sources" do
    {buffer, _coordinator} = start_buffer(merger: RejectingMerger)

    assert Buffer.submit(buffer, [], %{}) == {:error, :invalid_submission}
    assert Buffer.submit(buffer, [], %{source: "visitor"}) == {:error, :invalid_submission}
    assert Buffer.submit(buffer, [], %{source: "untrusted"}) == {:error, :invalid_submission}
    assert Buffer.depth(buffer) == 0
    refute_receive {:timer_scheduled, ^buffer, {:drain, _token}, _delay}, 50
  end

  test "duplicate checkpoint-only submissions preserve queue order and remain silent" do
    {buffer, _coordinator} = start_buffer(merger: RejectingMerger)
    Phoenix.PubSub.subscribe(Worldloom.PubSub, Coordinator.topic())

    first = Task.async(fn -> Buffer.submit(buffer, [], checkpoint("same-cursor")) end)
    second = Task.async(fn -> Buffer.submit(buffer, [], checkpoint("same-cursor")) end)

    fire_timer(buffer, 250)
    fire_timer(buffer, 250)

    assert Task.await(first) == :ok
    assert Task.await(second) == :ok
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "same-cursor"
    refute_receive {:loom_snapshot, _snapshot}, 50
    refute_receive {:loom_event, _instruction}, 50
  end

  test "a checkpoint-only persistence failure follows the bounded retry schedule" do
    {buffer, _coordinator} = start_buffer(merger: RejectingMerger)
    invalid_checkpoint = checkpoint(String.duplicate("x", 8_193))
    submission = Task.async(fn -> Buffer.submit(buffer, [], invalid_checkpoint) end)

    fire_timer(buffer, 250)
    fire_timer(buffer, 250)
    fire_timer(buffer, 1_000)
    fire_timer(buffer, 5_000)

    assert Task.await(submission) == {:error, :persistence_unavailable}
    assert Buffer.depth(buffer) == 0
    assert Repo.get(FeedCheckpoint, "wikimedia") == nil
  end

  test "a checkpoint-only entry remains bounded behind a full event queue" do
    {buffer, _coordinator} = start_buffer()

    event_submission =
      Task.async(fn ->
        Buffer.submit(buffer, Enum.map(1..16, &wikimedia_bucket/1), checkpoint("cursor-16"))
      end)

    assert_receive {:timer_scheduled, ^buffer, {:drain, _token}, 250}, 500

    checkpoint_submission =
      Task.async(fn -> Buffer.submit(buffer, [], checkpoint("cursor-17")) end)

    assert Buffer.depth(buffer) <= 16
    send(buffer, :drain)
    :sys.get_state(buffer)
    drain_until_complete(buffer, [event_submission, checkpoint_submission])

    assert Enum.sum(Enum.map(Store.latest(), & &1.payload["count"])) == 16
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "cursor-17"
  end

  test "visitor commits bypass a waiting external queue" do
    {buffer, coordinator} = start_buffer()

    submission =
      Task.async(fn -> Buffer.submit(buffer, [source_event(1)], checkpoint("cursor-1")) end)

    assert_receive {:timer_scheduled, ^buffer, {:drain, _token}, 250}, 500

    visitor =
      SourceEvent.new!(%{
        kind: :tug,
        source: :visitor,
        external_id: nil,
        occurred_at: ~U[2026-08-03 12:00:00.000000Z],
        lane: 0.5,
        intensity: 0.5,
        payload: %{"summary" => "A visitor tugged the living edge"}
      })

    assert {:ok, visitor_event} =
             Coordinator.commit_visitor(coordinator, visitor, "visitor-request-nonce")

    assert visitor_event.source == "visitor"
    assert Buffer.depth(buffer) == 1
    assert Task.yield(submission, 0) == nil

    send(buffer, :drain)
    assert Task.await(submission) == :ok
  end

  test "persistence failures retry after 250 ms, 1 second, and 5 seconds before failing callers" do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:worldloom, :signals, :retry],
        fn _event, measurements, metadata, test_process ->
          send(test_process, {:retry_telemetry, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {buffer, _coordinator} = start_buffer()
    invalid_checkpoint = checkpoint(String.duplicate("x", 8_193))

    submission =
      Task.async(fn -> Buffer.submit(buffer, [source_event(1)], invalid_checkpoint) end)

    fire_timer(buffer, 250)
    fire_timer(buffer, 250)
    fire_timer(buffer, 1_000)
    fire_timer(buffer, 5_000)

    assert Task.await(submission) == {:error, :persistence_unavailable}
    assert Buffer.depth(buffer) == 0
    assert Store.latest() == []
    assert Repo.get(FeedCheckpoint, "wikimedia") == nil

    assert_receive {:retry_telemetry, %{count: 1, delay: 250},
                    %{source: :wikimedia, operation: :persistence, attempt: 1}},
                   500

    assert_receive {:retry_telemetry, %{count: 1, delay: 1_000},
                    %{source: :wikimedia, operation: :persistence, attempt: 2}},
                   500

    assert_receive {:retry_telemetry, %{count: 1, delay: 5_000},
                    %{source: :wikimedia, operation: :persistence, attempt: 3}},
                   500
  end

  test "an exhausted event failure aborts later source events before their checkpoint can advance" do
    {:ok, failing_coordinator} = FailingCoordinator.start_link(self())
    {buffer, _coordinator} = start_buffer(coordinator: failing_coordinator)

    submission =
      Task.async(fn ->
        Buffer.submit(buffer, Enum.map(1..2, &source_event/1), checkpoint("cursor-2"))
      end)

    fire_timer(buffer, 250)
    fire_timer(buffer, 250)
    fire_timer(buffer, 1_000)
    fire_timer(buffer, 5_000)

    assert Task.yield(submission, 100) == {:ok, {:error, :persistence_unavailable}}
    assert Buffer.depth(buffer) == 0

    assert_received {:coordinator_commit, "buffer-revision-1", nil}
    refute_received {:coordinator_commit, "buffer-revision-2", _checkpoint}
  end

  test "a crash exits waiting callers without advancing their checkpoint" do
    {buffer, _coordinator} = start_buffer()
    test_process = self()

    spawn(fn ->
      outcome =
        try do
          Buffer.submit(buffer, [source_event(1)], checkpoint("must-not-advance"))
        catch
          :exit, reason -> {:exit, reason}
        end

      send(test_process, {:caller_outcome, outcome})
    end)

    assert_receive {:timer_scheduled, ^buffer, {:drain, _token}, 250}, 500
    GenServer.stop(buffer)

    assert_receive {:caller_outcome, {:exit, _reason}}, 500
    assert Repo.get(FeedCheckpoint, "wikimedia") == nil
    assert Store.latest() == []
  end

  defp start_buffer(options \\ []) do
    topic = "buffer:test:#{System.unique_integer([:positive, :monotonic])}"

    coordinator =
      case Keyword.fetch(options, :coordinator) do
        {:ok, coordinator} ->
          coordinator

        :error ->
          start_supervised!(
            {CoordinatorTestStore,
             delegate: Store,
             commit_snapshot: CoordinatorTestStore.empty_snapshot(Store.highest_sequence())}
          )

          {:ok, coordinator} =
            Coordinator.start_link(
              name: nil,
              topic: topic,
              store: CoordinatorTestStore
            )

          coordinator
      end

    test_process = self()
    clock = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    health_registry =
      Keyword.get_lazy(options, :health_registry, &start_health_registry/0)

    timer = fn process, message, delay ->
      send(test_process, {:timer_scheduled, process, message, delay})
      make_ref()
    end

    {:ok, buffer} =
      Buffer.start_link(
        name: nil,
        coordinator: coordinator,
        merger: Keyword.get(options, :merger, Worldloom.Signals.Merger),
        health_registry: health_registry,
        clock: fn -> Agent.get(clock, & &1) end,
        timer: timer
      )

    Process.put({__MODULE__, buffer, :clock}, clock)

    on_exit(fn ->
      Process.delete({__MODULE__, buffer, :clock})
      if Process.alive?(buffer), do: GenServer.stop(buffer)
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
    end)

    {buffer, coordinator}
  end

  defp start_health_registry do
    start_supervised!(%{
      id: make_ref(),
      start:
        {HealthRegistry, :start_link,
         [[name: nil, monitor: nil, clock: fn -> ~U[2026-08-08 12:00:00Z] end]]}
    })
  end

  defp fire_timer(buffer, expected_delay) do
    assert_receive {:timer_scheduled, ^buffer, message, ^expected_delay}, 500
    clock = Process.get({__MODULE__, buffer, :clock}) || flunk("missing buffer clock")
    Agent.update(clock, &(&1 + expected_delay))
    send(buffer, message)
    :sys.get_state(buffer)
  end

  defp drain_until_complete(buffer, submission) when not is_list(submission) do
    if Buffer.depth(buffer) == 0 do
      assert Task.await(submission) == :ok
    else
      fire_timer(buffer, 250)
      drain_until_complete(buffer, submission)
    end
  end

  defp drain_until_complete(buffer, submissions) when is_list(submissions) do
    if Buffer.depth(buffer) == 0 do
      Enum.each(submissions, fn submission -> assert Task.await(submission) == :ok end)
    else
      fire_timer(buffer, 250)
      drain_until_complete(buffer, submissions)
    end
  end

  defp start_submission(buffer, events, checkpoint, expected_depth) do
    submission = Task.async(fn -> Buffer.submit(buffer, events, checkpoint) end)
    await_depth(buffer, expected_depth, 100)
    submission
  end

  defp await_depth(buffer, expected_depth, attempts) do
    if Buffer.depth(buffer) == expected_depth do
      :ok
    else
      if attempts == 0 do
        flunk("buffer depth did not reach #{expected_depth}")
      else
        Process.sleep(1)
        await_depth(buffer, expected_depth, attempts - 1)
      end
    end
  end

  defp receive_commit do
    assert_receive {:coordinator_commit, source, external_ids, _checkpoint}, 500
    {source, external_ids}
  end

  defp signal_event(source, index) do
    {kind, payload, render_identity} = signal_attributes(source, index)

    SourceEvent.new!(%{
      kind: kind,
      source: source,
      external_id: "#{source}-#{index}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
      lane: 0.4,
      intensity: 0.6,
      payload: payload,
      render_identity: render_identity
    })
  end

  defp signal_attributes(:wikimedia, index),
    do: {:wikimedia, wikimedia_payload(index, "Wikimedia window #{index}"), nil}

  defp signal_attributes(:bluesky, _index) do
    {:public_activity,
     %{
       "summary" => "Public activity moved through the weave",
       "window_count" => 1,
       "window_span_seconds" => 4,
       "total_actions" => 1,
       "original_posts" => 1,
       "replies" => 0,
       "reposts" => 0,
       "creates" => 1,
       "updates" => 0,
       "deletes" => 0,
       "truncated" => false
     }, nil}
  end

  defp signal_attributes(:ripe_ris, _index) do
    {:route_change,
     %{
       "summary" => "Public routes shifted through the weave",
       "window_count" => 1,
       "window_span_seconds" => 4,
       "announced" => 1,
       "withdrawn" => 0,
       "ipv4" => 1,
       "ipv6" => 0,
       "collector_observations" => 1,
       "peer_observations" => 1,
       "truncated" => false
     }, nil}
  end

  defp signal_attributes(:solana, index) do
    {:slot,
     %{
       "summary" => "Public slots advanced through the weave",
       "window_count" => 1,
       "window_span_seconds" => 4,
       "slot_count" => 1,
       "first_slot" => index,
       "last_slot" => index,
       "gap_count" => 0,
       "truncated" => false
     }, nil}
  end

  defp signal_attributes(:drand, index) do
    render_identity =
      :sha256
      |> :crypto.hash("drand-round-#{index}")
      |> Base.encode16(case: :lower)

    {:randomness, %{"summary" => "Public randomness round #{index}", "round" => index},
     render_identity}
  end

  defp signal_attributes(:usgs, index),
    do: {:earthquake, %{"summary" => "Earthquake observation #{index}"}, nil}

  defp source_event(index) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: "buffer-revision-#{index}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
      lane: 0.4,
      intensity: 0.6,
      payload: wikimedia_payload(index, "Buffered revision #{index} entered the weave")
    })
  end

  defp wikimedia_bucket(index) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: "bucket-#{index}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
      lane: 0.4,
      intensity: 0.02,
      payload: wikimedia_payload(index, "One edit entered the weave")
    })
  end

  defp wikimedia_payload(index, summary) do
    %{
      "summary" => summary,
      "window_count" => 1,
      "window_span_seconds" => 4,
      "count" => 1,
      "total_absolute_byte_delta" => index,
      "language_buckets" => %{
        "current_1" => 1,
        "current_2" => 0,
        "current_3" => 0,
        "current_4" => 0,
        "current_5" => 0
      },
      "edit_types" => %{
        "categorize" => 0,
        "edit" => 1,
        "external" => 0,
        "log" => 0,
        "new" => 0
      },
      "dominant_edit_type" => "edit",
      "truncated" => false
    }
  end

  defp checkpoint(cursor), do: checkpoint(:wikimedia, cursor)

  defp checkpoint(source, cursor) do
    %{
      source: Atom.to_string(source),
      cursor: cursor,
      etag: nil,
      last_successful_at: ~U[2026-08-03 12:10:00.000000Z],
      metadata: %{}
    }
  end
end
