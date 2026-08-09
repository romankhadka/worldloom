defmodule Worldloom.Signals.WikimediaWorkerTest do
  use Worldloom.DataCase

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Loom.LiveProjection
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store
  alias Worldloom.Signals.HealthMonitor
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.WikimediaWorker

  @fixture "test/support/fixtures/feeds/wikimedia_frames.json"
  @window_start ~U[2026-08-03 12:00:00.000000Z]

  test "projects valid Wikimedia lifecycle transitions without exposing stream details" do
    [first | _rest] = read_frames()
    test_process = self()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)
    clock_reader = fn -> Agent.get(clock, & &1) end
    monitor_name = Worldloom.Signals.WikimediaWorkerTest.HealthMonitorProcess
    registry = start_health_registry(clock_reader, monitor_name)

    {:ok, monitor} =
      HealthMonitor.start_link(
        name: monitor_name,
        registry: registry,
        broadcaster: fn health -> send(test_process, {:health, health}) end,
        clock: clock_reader,
        timer: fn _process, _message, _delay -> make_ref() end
      )

    assert_receive {:health, %{wikimedia: %{state: :disconnected}}}, 500

    stream = fn _url, _cursor, callback ->
      callback.(frame("cursor-health", first))
      send(test_process, {:valid_frame_accepted, self()})

      receive do
        :finish_stream -> {:error, :disconnected}
      end
    end

    {worker, _task_supervisor} =
      start_worker(
        stream: stream,
        buffer: fn _events, _checkpoint -> :ok end,
        clock: clock_reader,
        health_registry: registry
      )

    assert_receive {:valid_frame_accepted, stream_pid}, 500
    assert_receive {:health, connected_health}, 500
    assert connected_health.wikimedia == %{state: :quiet, observed_at: nil}

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:05Z] end)
    send(worker, :flush_bucket)
    :sys.get_state(worker)
    send(monitor, :health_registry_changed)

    assert_receive {:health, live_health}, 500

    assert live_health.wikimedia == %{
             state: :live,
             observed_at: ~U[2026-08-03 12:00:05Z]
           }

    send(stream_pid, :finish_stream)
    assert_receive {:health, disconnected_health}, 500

    assert disconnected_health.wikimedia == %{
             state: :disconnected,
             observed_at: ~U[2026-08-03 12:00:05Z]
           }
  end

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

  test "restores Last-Event-ID at the sixty-second replay boundary" do
    insert_checkpoint(%{"last_event_at" => "2026-08-03T12:00:00Z"})
    test_process = self()

    stream = fn _url, cursor, _callback ->
      send(test_process, {:replay_cursor, cursor})

      receive do
        :finish_replay_boundary -> {:error, :disconnected}
      end
    end

    {_worker, _task_supervisor} =
      start_worker(stream: stream, clock: fn -> ~U[2026-08-03 12:01:00Z] end)

    assert_receive {:replay_cursor, "saved-cursor"}, 500
  end

  test "moves to the live edge and reports a replay gap beyond sixty seconds" do
    marker = "private-replay-cursor"
    insert_checkpoint(%{"last_event_at" => "2026-08-03T11:59:59Z"}, marker)
    test_process = self()
    now = ~U[2026-08-03 12:01:00Z]
    registry = start_health_registry(fn -> now end)

    stream = fn _url, cursor, _callback ->
      send(test_process, {:live_edge_cursor, cursor})

      receive do
        :finish_stale_replay -> {:error, :disconnected}
      end
    end

    {worker, _task_supervisor} =
      start_worker(stream: stream, clock: fn -> now end, health_registry: registry)

    assert_receive {:live_edge_cursor, nil}, 500
    state = :sys.get_state(worker)
    assert state.cursor == nil
    assert state.latest_cursor == nil
    refute inspect(state) =~ marker

    observation = HealthRegistry.current(registry).wikimedia
    assert observation.drops == 1
    assert observation.last_reason == :replay
  end

  test "drops a cursor when a same-process reconnect crosses the replay horizon" do
    insert_checkpoint(%{"last_event_at" => "2026-08-03T12:00:00Z"})
    test_process = self()
    clock = start_agent(fn -> ~U[2026-08-03 12:00:01Z] end)
    connections = start_agent(fn -> 0 end)
    registry = start_health_registry(fn -> Agent.get(clock, & &1) end)

    stream = fn _url, cursor, _callback ->
      connection = Agent.get_and_update(connections, fn count -> {count, count + 1} end)
      send(test_process, {:reconnect_cursor, connection, cursor})

      if connection == 0 do
        {:error, :disconnected}
      else
        receive do
          :finish_delayed_reconnect -> {:error, :disconnected}
        end
      end
    end

    {worker, _task_supervisor} =
      start_worker(
        stream: stream,
        clock: fn -> Agent.get(clock, & &1) end,
        health_registry: registry
      )

    assert_receive {:reconnect_cursor, 0, "saved-cursor"}, 500
    assert_receive {:timer, ^worker, :connect, 1_000}, 500

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:01:01Z] end)
    send(worker, :connect)

    assert_receive {:reconnect_cursor, 1, nil}, 500
    assert :sys.get_state(worker).cursor == nil

    observation = HealthRegistry.current(registry).wikimedia
    assert observation.drops == 1
    assert observation.last_reason == :replay
  end

  test "consumes multiple bounded replay windows and counts only durable recovery" do
    [first | _remaining] = read_frames()
    now = ~U[2026-08-03 12:00:12Z]
    clock = start_agent(fn -> now end)
    registry = start_health_registry(fn -> Agent.get(clock, & &1) end)
    test_process = self()
    insert_checkpoint(%{"last_event_at" => "2026-08-03T12:00:00Z"}, "replay-cursor")

    replay_frames =
      for {second, index} <- Enum.with_index([0, 4, 8, 12], 1) do
        occurred_at = DateTime.add(@window_start, second, :second)
        frame("replay-#{index}", put_in(first, ["meta", "dt"], DateTime.to_iso8601(occurred_at)))
      end

    stream = fn _url, cursor, callback ->
      send(test_process, {:multi_replay_started, cursor})
      Enum.each(replay_frames, callback)
      send(test_process, :multi_replay_finished)

      receive do
        :finish_multi_replay -> {:error, :disconnected}
      end
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:replay_submission, events, checkpoint})
      :ok
    end

    {worker, _task_supervisor} =
      start_worker(
        stream: stream,
        buffer: buffer,
        clock: fn -> Agent.get(clock, & &1) end,
        health_registry: registry
      )

    assert_receive {:multi_replay_started, "replay-cursor"}, 500
    assert_receive :multi_replay_finished, 500

    Agent.update(clock, fn _time -> ~U[2026-08-03 12:00:17Z] end)
    send(worker, :flush_bucket)

    recovered_windows =
      for _index <- 1..4 do
        assert_receive {:replay_submission, [event], _checkpoint}, 500
        event
      end

    assert Enum.map(recovered_windows, & &1.occurred_at) == [
             ~U[2026-08-03 12:00:00.000000Z],
             ~U[2026-08-03 12:00:04.000000Z],
             ~U[2026-08-03 12:00:08.000000Z],
             ~U[2026-08-03 12:00:12.000000Z]
           ]

    state = :sys.get_state(worker)
    assert state.replay_pending == false

    observation = HealthRegistry.current(registry).wikimedia
    assert observation.recovered_windows == 3
    assert observation.last_activity_at == ~U[2026-08-03 12:00:17Z]
  end

  test "persists a bounded late replay as history-only without moving the live window" do
    [first | _remaining] = read_frames()
    now = ~U[2026-08-03 12:01:03Z]
    replay_time = ~U[2026-08-03 12:00:03Z]

    anchor =
      SourceEvent.new!(%{
        kind: :earthquake,
        source: :usgs,
        external_id: "recovery-live-anchor",
        occurred_at: now,
        lane: 0.5,
        intensity: 0.5,
        payload: %{"summary" => "A current public anchor held the live window"}
      })

    assert {:ok, [_stored_anchor]} =
             Store.commit_external(
               [anchor],
               %{
                 source: "usgs",
                 cursor: nil,
                 etag: nil,
                 last_successful_at: now,
                 metadata: %{}
               }
             )

    insert_checkpoint(%{"last_event_at" => DateTime.to_iso8601(replay_time)}, "replay-cursor")

    stored_anchor = Store.latest() |> List.last()
    initial_snapshot = LiveProjection.build([stored_anchor], nil, stored_anchor.id)

    test_process = self()
    clock = start_agent(fn -> now end)
    registry = start_health_registry(fn -> Agent.get(clock, & &1) end)

    replay_frame =
      frame("recovered-cursor", put_in(first, ["meta", "dt"], DateTime.to_iso8601(replay_time)))

    stream = fn _url, cursor, callback ->
      send(test_process, {:history_replay_started, cursor})
      callback.(replay_frame)
      send(test_process, :history_replay_accepted)

      receive do
        :finish_history_replay -> {:error, :disconnected}
      end
    end

    buffer = fn events, checkpoint ->
      case Store.commit_external(events, checkpoint) do
        {:ok, inserted} ->
          send(test_process, {:history_replay_persisted, inserted})
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end

    {worker, _task_supervisor} =
      start_worker(
        stream: stream,
        buffer: buffer,
        clock: fn -> Agent.get(clock, & &1) end,
        health_registry: registry
      )

    assert_receive {:history_replay_started, "replay-cursor"}, 500
    assert_receive :history_replay_accepted, 500
    Agent.update(clock, fn _time -> ~U[2026-08-03 12:01:05Z] end)
    send(worker, :flush_bucket)

    assert_receive {:history_replay_persisted, [recovered]}, 500
    :sys.get_state(worker)

    observation = HealthRegistry.current(registry).wikimedia
    assert observation.connection == :connected
    assert observation.last_contact_at == ~U[2026-08-03 12:01:05Z]
    assert observation.last_activity_at == ~U[2026-08-03 12:01:05Z]
    assert observation.recovered_windows == 1

    recovered_snapshot =
      LiveProjection.build(
        [stored_anchor, recovered],
        nil,
        recovered.id,
        initial_snapshot.window_end
      )

    assert recovered.occurred_at == ~U[2026-08-03 12:00:00.000000Z]
    assert recovered_snapshot.commit_watermark == recovered.id
    assert recovered_snapshot.window_end == initial_snapshot.window_end

    assert Enum.map(recovered_snapshot.display_events, & &1.id) ==
             Enum.map(initial_snapshot.display_events, & &1.id)

    refute recovered in recovered_snapshot.display_events
    refute recovered in recovered_snapshot.memory_events
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

    options =
      Keyword.put_new_lazy(options, :health_registry, fn ->
        start_health_registry(Keyword.fetch!(options, :clock))
      end)

    {:ok, worker} = WikimediaWorker.start_link(options)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :shutdown)
      if Process.alive?(task_supervisor), do: Process.exit(task_supervisor, :shutdown)
    end)

    {worker, task_supervisor}
  end

  defp insert_checkpoint(
         metadata \\ %{"last_event_at" => "2026-08-03T12:00:00Z"},
         cursor \\ "saved-cursor"
       ) do
    %FeedCheckpoint{}
    |> FeedCheckpoint.changeset(%{
      source: "wikimedia",
      cursor: cursor,
      etag: nil,
      last_successful_at: ~U[2026-08-03 11:00:00Z],
      metadata: metadata
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

  defp start_health_registry(clock, monitor \\ nil) do
    start_supervised!(%{
      id: make_ref(),
      start: {HealthRegistry, :start_link, [[name: nil, monitor: monitor, clock: clock]]}
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
