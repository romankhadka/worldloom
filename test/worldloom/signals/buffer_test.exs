defmodule Worldloom.Signals.BufferTest do
  use Worldloom.DataCase

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.CoordinatorTestStore
  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store
  alias Worldloom.Signals.Buffer

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
        fn _event_name, measurements, _metadata, test_process ->
          send(test_process, {:buffer_depth, measurements.depth})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    events = Enum.map(1..40, &wikimedia_bucket/1)
    submission = Task.async(fn -> Buffer.submit(buffer, events, checkpoint("cursor-40")) end)

    assert_receive {:timer_scheduled, ^buffer, :drain, 250}, 500
    assert Buffer.depth(buffer) <= 16

    send(buffer, :drain)
    :sys.get_state(buffer)
    drain_until_complete(buffer, submission)

    persisted = Store.latest()
    assert length(persisted) <= 16
    assert Enum.sum(Enum.map(persisted, & &1.payload["count"])) == 40
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "cursor-40"
    assert_receive {:buffer_depth, 0}, 500
  end

  test "empty successful submissions commit their checkpoint immediately" do
    {buffer, _coordinator} = start_buffer()

    assert Buffer.submit(buffer, [], checkpoint("empty-cursor")) == :ok
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "empty-cursor"
    refute_receive {:timer_scheduled, ^buffer, :drain, _delay}, 50
  end

  test "visitor commits bypass a waiting external queue" do
    {buffer, coordinator} = start_buffer()

    submission =
      Task.async(fn -> Buffer.submit(buffer, [source_event(1)], checkpoint("cursor-1")) end)

    assert_receive {:timer_scheduled, ^buffer, :drain, 250}, 500

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

    assert_receive {:timer_scheduled, ^buffer, :drain, 250}, 500
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

    timer = fn process, message, delay ->
      send(test_process, {:timer_scheduled, process, message, delay})
      make_ref()
    end

    {:ok, buffer} =
      Buffer.start_link(
        name: nil,
        coordinator: coordinator,
        clock: fn -> 0 end,
        timer: timer
      )

    on_exit(fn ->
      if Process.alive?(buffer), do: GenServer.stop(buffer)
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
    end)

    {buffer, coordinator}
  end

  defp fire_timer(buffer, expected_delay) do
    assert_receive {:timer_scheduled, ^buffer, message, ^expected_delay}, 500
    send(buffer, message)
    :sys.get_state(buffer)
  end

  defp drain_until_complete(buffer, submission) do
    if Buffer.depth(buffer) == 0 do
      assert Task.await(submission) == :ok
    else
      fire_timer(buffer, 250)
      drain_until_complete(buffer, submission)
    end
  end

  defp source_event(index) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: "buffer-revision-#{index}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
      lane: 0.4,
      intensity: 0.6,
      payload: %{"summary" => "Buffered revision #{index} entered the weave"}
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
      payload: %{
        "summary" => "One edit entered the weave",
        "count" => 1,
        "total_absolute_byte_delta" => index,
        "languages" => %{"en" => 1},
        "dominant_edit_type" => "edit"
      }
    })
  end

  defp checkpoint(cursor) do
    %{
      source: "wikimedia",
      cursor: cursor,
      etag: nil,
      last_successful_at: ~U[2026-08-03 12:10:00.000000Z],
      metadata: %{}
    }
  end
end
