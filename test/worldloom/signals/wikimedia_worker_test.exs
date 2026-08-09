defmodule Worldloom.Signals.WikimediaWorkerTest do
  use Worldloom.DataCase

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Signals.WikimediaWorker

  @fixture "test/support/fixtures/feeds/wikimedia_frames.json"
  @window_start ~U[2026-08-03 12:00:00.000000Z]

  test "restores Last-Event-ID and closes a window only after its lateness grace" do
    attach_signal_telemetry()
    insert_checkpoint()
    [first | _rest] = read_frames()
    test_process = self()
    clock = start_agent(fn -> @window_start end)

    stream = fn url, cursor, callback ->
      send(test_process, {:stream_started, url, cursor})
      callback.(frame("cursor-41", first))
      send(test_process, :stream_callbacks_finished)
      {:error, :disconnected}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint, self()})

      receive do
        :release_submission -> :ok
      end
    end

    {worker, _task_supervisor} =
      start_worker(stream: stream, buffer: buffer, clock: fn -> Agent.get(clock, & &1) end)

    assert_receive {:stream_started, "https://example.test/wikimedia", "saved-cursor"}, 500
    assert_receive :stream_callbacks_finished, 500
    refute_receive {:submission, _events, _checkpoint, _worker}, 50

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:04.999999Z] end)
    send(worker, :flush_bucket)
    refute_receive {:submission, _events, _checkpoint, _worker}, 50

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:05.000000Z] end)
    send(worker, :flush_bucket)

    assert_receive {:submission, [event], checkpoint, blocked_worker}, 500
    assert event.external_id == "wikimedia-window:1785758400:4"
    assert event.occurred_at == @window_start
    assert event.payload["window_count"] == 1
    assert event.payload["window_span_seconds"] == 4
    assert checkpoint.cursor == "cursor-41"
    assert checkpoint.metadata["last_event_at"] == "2026-08-03T12:00:00Z"
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "saved-cursor"

    send(blocked_worker, :release_submission)
    :sys.get_state(worker)

    assert_receive {:feed_telemetry, %{count: 1, duration: duration},
                    %{source: :wikimedia, status: :success, attempt: attempt}},
                   500

    assert is_integer(duration) and duration >= 0
    assert is_integer(attempt) and attempt >= 0
  end

  test "accepts out-of-order frames in the grace period and persists windows once in order" do
    [first, second, third] = read_frames()
    test_process = self()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)

    stream = fn _url, _cursor, callback ->
      callback.(frame("cursor-1", first))
      callback.(frame("cursor-2", put_in(second, ["meta", "dt"], "2026-08-03T12:00:04Z")))
      callback.(frame("cursor-3", put_in(third, ["meta", "dt"], "2026-08-03T12:00:03Z")))
      send(test_process, :stream_callbacks_finished)
      {:error, :disconnected}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint})
      :ok
    end

    {worker, _task_supervisor} =
      start_worker(stream: stream, buffer: buffer, clock: fn -> Agent.get(clock, & &1) end)

    assert_receive :stream_callbacks_finished, 500
    refute_receive {:submission, _events, _checkpoint}, 50

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:05Z] end)
    send(worker, :flush_bucket)

    assert_receive {:submission, [first_window], first_checkpoint}, 500
    assert first_window.occurred_at == @window_start
    assert first_window.payload["count"] == 2
    assert first_checkpoint.cursor == "cursor-3"

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:09Z] end)
    send(worker, :flush_bucket)

    assert_receive {:submission, [second_window], second_checkpoint}, 500
    assert second_window.occurred_at == ~U[2026-08-03 12:00:04.000000Z]
    assert second_window.payload["count"] == 1
    assert second_checkpoint.cursor == "cursor-3"
    refute_receive {:submission, _events, _checkpoint}, 50
  end

  test "an empty elapsed window advances a changed cursor without fabricating skipped windows" do
    attach_signal_telemetry()
    test_process = self()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)

    stream = fn _url, _cursor, callback ->
      callback.(%{id: "heartbeat-1", event: nil, data: ""})
      send(test_process, :stream_callbacks_finished)
      {:error, :disconnected}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint})
      :ok
    end

    {worker, _task_supervisor} =
      start_worker(stream: stream, buffer: buffer, clock: fn -> Agent.get(clock, & &1) end)

    assert_receive :stream_callbacks_finished, 500
    refute_receive {:submission, _events, _checkpoint}, 50

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:05Z] end)
    send(worker, :flush_bucket)

    assert_receive {:submission, [], checkpoint}, 500
    assert checkpoint.cursor == "heartbeat-1"

    assert_receive {:feed_telemetry, %{count: 0}, %{source: :wikimedia, status: :success}},
                   500

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:10:00Z] end)
    send(worker, :flush_bucket)
    refute_receive {:submission, _events, _checkpoint}, 100
  end

  test "a large time jump closes only observed windows" do
    [first, second | _rest] = read_frames()
    test_process = self()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)

    stream = fn _url, _cursor, callback ->
      callback.(frame("cursor-1", first))

      callback.(frame("cursor-2", put_in(second, ["meta", "dt"], "2026-08-03T12:00:40Z")))

      send(test_process, :stream_callbacks_finished)
      {:error, :disconnected}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint})
      :ok
    end

    {worker, _task_supervisor} =
      start_worker(stream: stream, buffer: buffer, clock: fn -> Agent.get(clock, & &1) end)

    assert_receive :stream_callbacks_finished, 500
    assert_receive {:submission, [first_window], _checkpoint}, 500
    assert first_window.occurred_at == @window_start

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:45Z] end)
    send(worker, :flush_bucket)
    assert_receive {:submission, [jumped_window], _checkpoint}, 500
    assert jumped_window.occurred_at == ~U[2026-08-03 12:00:40.000000Z]
    refute_receive {:submission, _events, _checkpoint}, 100
  end

  test "a failed close retains the same window for the next timer retry" do
    [first | _rest] = read_frames()
    test_process = self()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)
    attempts = start_agent(fn -> 0 end)

    stream = fn _url, _cursor, callback ->
      callback.(frame("cursor-retry", first))
      send(test_process, :stream_callbacks_finished)
      {:error, :disconnected}
    end

    buffer = fn events, checkpoint ->
      attempt = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)
      send(test_process, {:submission, events, checkpoint, attempt})
      if attempt == 0, do: {:error, :database_down}, else: :ok
    end

    {worker, _task_supervisor} =
      start_worker(stream: stream, buffer: buffer, clock: fn -> Agent.get(clock, & &1) end)

    assert_receive :stream_callbacks_finished, 500
    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:05Z] end)
    send(worker, :flush_bucket)
    assert_receive {:submission, [failed_window], _checkpoint, 0}, 500

    send(worker, :flush_bucket)
    assert_receive {:submission, [retried_window], _checkpoint, 1}, 500
    assert retried_window.external_id == failed_window.external_id
    refute_receive {:submission, _events, _checkpoint, _attempt}, 100
  end

  defp attach_signal_telemetry do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:worldloom, :signals, :feed], [:worldloom, :signals, :retry]],
        fn
          [:worldloom, :signals, :feed], measurements, metadata, test_process ->
            send(test_process, {:feed_telemetry, measurements, metadata})

          [:worldloom, :signals, :retry], measurements, metadata, test_process ->
            send(test_process, {:retry_telemetry, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp start_worker(overrides) do
    test_process = self()
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    timer = fn process, message, delay ->
      send(test_process, {:timer, process, message, delay})
      make_ref()
    end

    options =
      Keyword.merge(
        [
          name: nil,
          url: "https://example.test/wikimedia",
          task_supervisor: task_supervisor,
          clock: fn -> @window_start end,
          random: fn -> 0.5 end,
          timer: timer
        ],
        overrides
      )

    {:ok, worker} = WikimediaWorker.start_link(options)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :shutdown)
      if Process.alive?(task_supervisor), do: Process.exit(task_supervisor, :shutdown)
    end)

    {worker, task_supervisor}
  end

  defp insert_checkpoint do
    %FeedCheckpoint{}
    |> FeedCheckpoint.changeset(%{
      source: "wikimedia",
      cursor: "saved-cursor",
      etag: nil,
      last_successful_at: ~U[2026-08-03 11:00:00Z],
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp read_frames, do: @fixture |> File.read!() |> Jason.decode!()
  defp frame(id, payload), do: %{id: id, event: "recentchange", data: Jason.encode!(payload)}

  defp start_agent(initializer) do
    start_supervised!(%{
      id: make_ref(),
      start: {Agent, :start_link, [initializer]}
    })
  end
end
