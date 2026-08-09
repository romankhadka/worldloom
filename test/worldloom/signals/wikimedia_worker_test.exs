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
    assert first_checkpoint.cursor == "cursor-1"

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:09Z] end)
    send(worker, :flush_bucket)

    assert_receive {:submission, [second_window], second_checkpoint}, 500
    assert second_window.occurred_at == ~U[2026-08-03 12:00:04.000000Z]
    assert second_window.payload["count"] == 1
    assert second_checkpoint.cursor == "cursor-3"
    refute_receive {:submission, _events, _checkpoint}, 50
  end

  test "a crash resumes before an accepted lookahead whose window was not durable" do
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

    {worker, task_supervisor} =
      start_worker(stream: stream, buffer: buffer, clock: fn -> Agent.get(clock, & &1) end)

    assert_receive :stream_callbacks_finished, 500
    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:05Z] end)
    send(worker, :flush_bucket)

    assert_receive {:submission, [_current_window], checkpoint}, 500
    assert checkpoint.cursor == "cursor-1"
    persist_checkpoint(checkpoint)

    GenServer.stop(worker)
    Supervisor.stop(task_supervisor)

    replayed_frame =
      frame("cursor-2", put_in(second, ["meta", "dt"], "2026-08-03T12:00:04Z"))

    restart_stream = fn url, cursor, callback ->
      send(test_process, {:restarted_stream, url, cursor})
      callback.(replayed_frame)
      send(test_process, :lookahead_replayed)

      receive do
        :finish_restart -> {:error, :disconnected}
      end
    end

    {restarted_worker, _restarted_supervisor} =
      start_worker(
        stream: restart_stream,
        buffer: buffer,
        clock: fn -> Agent.get(clock, & &1) end
      )

    assert_receive {:restarted_stream, "https://example.test/wikimedia", "cursor-1"}, 500
    assert_receive :lookahead_replayed, 500

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:09Z] end)
    send(restarted_worker, :flush_bucket)

    assert_receive {:submission, [replayed_window], replay_checkpoint}, 500
    assert replayed_window.occurred_at == ~U[2026-08-03 12:00:04.000000Z]
    assert replay_checkpoint.cursor == "cursor-2"
  end

  test "dropped cursors advance only after every earlier accepted window is durable" do
    [first, second | _rest] = read_frames()
    test_process = self()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint})
      :ok
    end

    {worker, _task_supervisor} =
      start_idle_worker(buffer: buffer, clock: fn -> Agent.get(clock, & &1) end)

    assert GenServer.call(worker, {:frame, frame("cursor-1", first)}) == :ok

    assert GenServer.call(
             worker,
             {:frame, frame("cursor-2", put_in(second, ["meta", "dt"], "2026-08-03T12:00:04Z"))}
           ) == :ok

    assert GenServer.call(worker, {:frame, %{id: "cursor-drop", data: "{"}}) == :ok

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:05Z] end)
    send(worker, :flush_bucket)
    assert_receive {:submission, [_first_window], first_checkpoint}, 500
    assert first_checkpoint.cursor == "cursor-1"

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:09Z] end)
    send(worker, :flush_bucket)
    assert_receive {:submission, [_second_window], second_checkpoint}, 500
    assert second_checkpoint.cursor == "cursor-drop"
  end

  test "frame handling closes on the observation clock boundary before routing" do
    [first, second, third] = read_frames()
    test_process = self()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint})
      :ok
    end

    {worker, _task_supervisor} =
      start_idle_worker(buffer: buffer, clock: fn -> Agent.get(clock, & &1) end)

    assert GenServer.call(worker, {:frame, frame("cursor-1", first)}) == :ok

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:04.999999Z] end)

    assert GenServer.call(
             worker,
             {:frame, frame("cursor-2", put_in(second, ["meta", "dt"], "2026-08-03T12:00:04Z"))}
           ) == :ok

    refute_receive {:submission, _events, _checkpoint}, 50

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:05.000000Z] end)

    assert GenServer.call(
             worker,
             {:frame, frame("cursor-3", put_in(third, ["meta", "dt"], "2026-08-03T12:00:04Z"))}
           ) == :ok

    assert_receive {:submission, [closed_window], checkpoint}, 500
    assert closed_window.occurred_at == @window_start
    assert closed_window.payload["count"] == 1
    assert checkpoint.cursor == "cursor-1"

    state = :sys.get_state(worker)
    assert state.bucket.window_start == ~U[2026-08-03 12:00:04Z]
    assert state.bucket.count == 2
  end

  test "a failed observation-driven close rejects the new frame until retry succeeds" do
    [first, second | _rest] = read_frames()
    test_process = self()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)
    attempts = start_agent(fn -> 0 end)

    buffer = fn events, checkpoint ->
      attempt = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)
      send(test_process, {:submission, events, checkpoint, attempt})
      if attempt == 0, do: {:error, :database_down}, else: :ok
    end

    {worker, _task_supervisor} =
      start_idle_worker(buffer: buffer, clock: fn -> Agent.get(clock, & &1) end)

    assert GenServer.call(worker, {:frame, frame("cursor-1", first)}) == :ok
    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:05Z] end)
    next_frame = frame("cursor-2", put_in(second, ["meta", "dt"], "2026-08-03T12:00:04Z"))

    assert GenServer.call(worker, {:frame, next_frame}) == {:error, :database_down}
    assert_receive {:submission, [failed_window], failed_checkpoint, 0}, 500
    assert failed_window.payload["count"] == 1
    assert failed_checkpoint.cursor == "cursor-1"

    failed_state = :sys.get_state(worker)
    assert DateTime.compare(failed_state.bucket.window_start, @window_start) == :eq
    assert failed_state.bucket.count == 1
    assert failed_state.next_bucket == nil

    assert GenServer.call(worker, {:frame, next_frame}) == :ok
    assert_receive {:submission, [retried_window], retried_checkpoint, 1}, 500
    assert retried_window.external_id == failed_window.external_id
    assert retried_checkpoint.cursor == "cursor-1"

    accepted_state = :sys.get_state(worker)
    assert accepted_state.bucket.window_start == ~U[2026-08-03 12:00:04Z]
    assert accepted_state.bucket.count == 1
  end

  test "ignored frames preserve reconnect backoff while a heartbeat resets it" do
    [first | _rest] = read_frames()
    invocation = start_agent(fn -> 0 end)

    stream = fn _url, _cursor, callback ->
      attempt = Agent.get_and_update(invocation, fn count -> {count, count + 1} end)

      case attempt do
        0 ->
          :ok

        1 ->
          callback.(%{id: "malformed-cursor", data: "{"})

        2 ->
          callback.(%{id: "invalid-cursor", data: "{}"})

        3 ->
          late = put_in(first, ["meta", "dt"], "2026-08-03T11:59:50Z")
          callback.(frame("late-cursor", late))

        4 ->
          callback.(%{id: "heartbeat-cursor", event: nil, data: ""})
      end

      {:error, :disconnected}
    end

    {worker, _task_supervisor} = start_worker(stream: stream)

    assert_receive {:timer, ^worker, :connect, 1_000}, 500
    send(worker, :connect)
    assert_receive {:timer, ^worker, :connect, 2_000}, 500
    send(worker, :connect)
    assert_receive {:timer, ^worker, :connect, 4_000}, 500
    send(worker, :connect)
    assert_receive {:timer, ^worker, :connect, 8_000}, 500
    send(worker, :connect)
    assert_receive {:timer, ^worker, :connect, 1_000}, 500

    assert Agent.get(invocation, & &1) == 5
    refute_received {:unexpected_submission, _events, _checkpoint}
  end

  test "cursor tracking stays constant-size under a high-rate lookahead" do
    [first, second | _rest] = read_frames()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)

    {worker, _task_supervisor} =
      start_idle_worker(clock: fn -> Agent.get(clock, & &1) end)

    initial_keys = worker |> :sys.get_state() |> Map.keys() |> Enum.sort()
    assert GenServer.call(worker, {:frame, frame("cursor-1", first)}) == :ok

    assert GenServer.call(
             worker,
             {:frame, frame("cursor-2", put_in(second, ["meta", "dt"], "2026-08-03T12:00:04Z"))}
           ) == :ok

    Enum.each(1..1_000, fn index ->
      assert GenServer.call(worker, {:frame, %{id: "drop-#{index}", data: "{"}}) == :ok
    end)

    state = :sys.get_state(worker)
    assert state.latest_cursor == "drop-1000"
    assert state.cursor_before_lookahead == "cursor-1"
    assert state |> Map.keys() |> Enum.sort() == initial_keys
    refute Map.has_key?(state, :cursor_entries)
    refute Map.has_key?(state, :cursor_runs)
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

  defp persist_checkpoint(attributes) do
    %FeedCheckpoint{}
    |> FeedCheckpoint.changeset(attributes)
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

  defp start_idle_worker(overrides) do
    test_process = self()

    stream = fn _url, _cursor, _callback ->
      send(test_process, :idle_stream_started)

      receive do
        :finish_idle_stream -> {:error, :disconnected}
      end
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:unexpected_submission, events, checkpoint})
      :ok
    end

    {worker, task_supervisor} =
      start_worker(Keyword.merge([stream: stream, buffer: buffer], overrides))

    assert_receive :idle_stream_started, 500
    {worker, task_supervisor}
  end
end
