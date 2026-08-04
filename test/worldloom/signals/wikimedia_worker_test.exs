defmodule Worldloom.Signals.WikimediaWorkerTest do
  use Worldloom.DataCase

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Signals.WikimediaWorker

  @fixture "test/support/fixtures/feeds/wikimedia_frames.json"
  @now ~U[2026-08-03 12:00:01.000000Z]

  test "restores the cursor and keeps the stream callback blocked until bucket durability" do
    attach_signal_telemetry()
    insert_checkpoint()
    [first | _rest] = @fixture |> File.read!() |> Jason.decode!()
    next = put_in(first, ["meta", "dt"], "2026-08-03T12:00:01Z")
    test_process = self()

    stream = fn url, cursor, callback ->
      send(test_process, {:stream_started, url, cursor})
      callback.(frame("cursor-41", first))
      callback.(frame("cursor-42", next))
      send(test_process, :stream_callbacks_finished)
      {:error, :disconnected}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint, self()})

      receive do
        :release_submission -> :ok
      end
    end

    {worker, _task_supervisor} = start_worker(stream: stream, buffer: buffer)

    assert_receive {:stream_started, "https://example.test/wikimedia", "saved-cursor"}, 500
    assert_receive {:submission, [event], checkpoint, blocked_worker}, 500
    assert event.source == :wikimedia
    assert checkpoint.cursor == "cursor-41"
    assert checkpoint.metadata["last_event_at"] == "2026-08-03T12:00:00Z"
    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "saved-cursor"
    refute_receive :stream_callbacks_finished, 50

    send(blocked_worker, :release_submission)
    assert_receive :stream_callbacks_finished, 500
    assert_receive {:timer, ^worker, :connect, 1_000}, 500

    assert_receive {:feed_telemetry, %{count: 1, duration: duration},
                    %{source: :wikimedia, status: :success, attempt: 0}},
                   500

    assert is_integer(duration) and duration >= 0

    assert_receive {:retry_telemetry, %{count: 1, delay: 1_000},
                    %{source: :wikimedia, operation: :connection, attempt: 1}},
                   500
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

  test "a successful heartbeat resets reconnect backoff and contact checkpoints are throttled" do
    test_process = self()
    invocation = start_supervised!({Agent, fn -> 0 end})

    stream = fn _url, _cursor, callback ->
      attempt = Agent.get_and_update(invocation, fn count -> {count, count + 1} end)

      if attempt > 0 do
        callback.(%{id: "heartbeat-#{attempt}", event: nil, data: ""})
      end

      {:error, :disconnected}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:heartbeat_checkpoint, events, checkpoint})
      :ok
    end

    {worker, _task_supervisor} = start_worker(stream: stream, buffer: buffer)

    assert_receive {:timer, ^worker, :connect, 1_000}, 500
    send(worker, :connect)
    assert_receive {:heartbeat_checkpoint, [], checkpoint}, 500
    assert checkpoint.cursor == "heartbeat-1"
    assert_receive {:timer, ^worker, :connect, 1_000}, 500

    send(worker, :connect)
    refute_receive {:heartbeat_checkpoint, [], _checkpoint}, 100
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
          clock: fn -> @now end,
          random: fn -> 0.5 end,
          timer: timer
        ],
        overrides
      )

    {:ok, worker} = WikimediaWorker.start_link(options)

    on_exit(fn ->
      Process.exit(worker, :shutdown)
      Process.exit(task_supervisor, :shutdown)
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

  defp frame(id, payload), do: %{id: id, event: "recentchange", data: Jason.encode!(payload)}
end
