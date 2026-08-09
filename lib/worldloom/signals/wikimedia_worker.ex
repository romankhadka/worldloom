defmodule Worldloom.Signals.WikimediaWorker do
  use GenServer

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Repo
  alias Worldloom.Signals.Backoff
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.Client
  alias Worldloom.Signals.Normalizer
  alias Worldloom.Signals.WikimediaBucket
  alias WorldloomWeb.Telemetry

  @source "wikimedia"
  @flush_interval 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, registration_options(name))
  end

  @impl true
  def init(options) do
    now = Keyword.get(options, :clock, &DateTime.utc_now/0).()
    checkpoint = Repo.get(FeedCheckpoint, @source)

    state = %{
      url: Keyword.fetch!(options, :url),
      cursor: checkpoint && checkpoint.cursor,
      bucket: WikimediaBucket.new(DateTime.add(now, -1, :second)),
      next_bucket: nil,
      latest_cursor: checkpoint && checkpoint.cursor,
      last_event_at: checkpoint && checkpoint.metadata["last_event_at"],
      attempt: 0,
      stream_pid: nil,
      stream_monitor: nil,
      task_supervisor: Keyword.get(options, :task_supervisor, Worldloom.Signals.StreamSupervisor),
      stream: Keyword.get(options, :stream, &Client.stream_sse/3),
      buffer: Keyword.get(options, :buffer, &Buffer.submit/2),
      clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
      random: Keyword.get(options, :random, &:rand.uniform/0),
      timer: Keyword.get(options, :timer, &Process.send_after/3)
    }

    state.timer.(self(), :flush_bucket, @flush_interval)
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, %{stream_pid: nil} = state) do
    worker = self()

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           stream_result =
             state.stream.(state.url, state.cursor, fn frame ->
               case GenServer.call(worker, {:frame, frame}, :infinity) do
                 :ok -> :ok
                 {:error, reason} -> exit({:durability_failure, reason})
               end
             end)

           send(worker, {:stream_ended, self(), stream_result})
         end) do
      {:ok, stream_pid} ->
        {:noreply, %{state | stream_pid: stream_pid, stream_monitor: Process.monitor(stream_pid)}}

      {:error, _reason} ->
        record_feed(:failure, 0, 0, state.attempt)
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:stream_ended, stream_pid, _reason}, %{stream_pid: stream_pid} = state) do
    Process.demonitor(state.stream_monitor, [:flush])
    record_feed(:failure, 0, 0, state.attempt)
    {:noreply, state |> clear_stream() |> schedule_reconnect()}
  end

  def handle_info(
        {:DOWN, monitor, :process, stream_pid, _reason},
        %{stream_pid: stream_pid, stream_monitor: monitor} = state
      ) do
    record_feed(:failure, 0, 0, state.attempt)
    {:noreply, state |> clear_stream() |> schedule_reconnect()}
  end

  def handle_info(:flush_bucket, state) do
    now = state.clock.()
    updated_state = maybe_flush_elapsed_bucket(state, now)
    updated_state.timer.(self(), :flush_bucket, @flush_interval)
    {:noreply, updated_state}
  end

  @impl true
  def handle_call({:frame, frame}, _from, state) do
    case accept_frame(state, frame) do
      {:ok, accepted_state} -> {:reply, :ok, %{accepted_state | attempt: 0}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp accept_frame(state, frame) do
    if frame[:data] == "" and state.next_bucket do
      accept_for_target(state, state.next_bucket, frame)
    else
      accept_for_target(state, state.bucket, frame)
    end
  end

  defp accept_for_target(state, target, frame) do
    case WikimediaBucket.add(target, frame) do
      {:ok, bucket} ->
        {:ok, put_target_bucket(state, target, bucket) |> observe_cursor(bucket.cursor)}

      {:heartbeat, bucket} ->
        {:ok, put_target_bucket(state, target, bucket) |> observe_cursor(bucket.cursor)}

      {:future, current_bucket, future_bucket} ->
        if target == state.bucket and state.next_bucket do
          accept_for_target(state, state.next_bucket, frame)
        else
          accept_future_bucket(state, target, current_bucket, future_bucket)
        end

      {:drop, _reason, _bucket} ->
        {:ok, state}
    end
  end

  defp accept_future_bucket(state, target, current_bucket, future_bucket) do
    cond do
      target == state.bucket and
          WikimediaBucket.elapsed?(current_bucket, future_bucket.window_start) ->
        case persist_bucket(state, current_bucket) do
          {:ok, persisted_state} ->
            {:ok,
             persisted_state
             |> Map.put(:bucket, future_bucket)
             |> Map.put(:next_bucket, nil)
             |> observe_cursor(future_bucket.cursor)}

          {:error, reason} ->
            {:error, reason}
        end

      target == state.bucket ->
        {:ok,
         state
         |> Map.put(:bucket, current_bucket)
         |> Map.put(:next_bucket, future_bucket)
         |> observe_cursor(future_bucket.cursor)}

      WikimediaBucket.elapsed?(state.bucket, future_bucket.window_start) ->
        case persist_bucket(state, state.bucket) do
          {:ok, persisted_state} ->
            {:ok,
             persisted_state
             |> Map.put(:bucket, current_bucket)
             |> Map.put(:next_bucket, future_bucket)
             |> observe_cursor(future_bucket.cursor)}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:ok, state}
    end
  end

  defp put_target_bucket(state, target, bucket) when target == state.bucket,
    do: %{state | bucket: bucket}

  defp put_target_bucket(state, _target, bucket), do: %{state | next_bucket: bucket}

  defp observe_cursor(state, cursor) when is_binary(cursor) and cursor != "",
    do: %{state | latest_cursor: cursor}

  defp observe_cursor(state, _cursor), do: state

  defp maybe_flush_elapsed_bucket(state, now) do
    if WikimediaBucket.elapsed?(state.bucket, now) do
      case persist_bucket(state, state.bucket) do
        {:ok, persisted_state} -> advance_elapsed_buckets(persisted_state, now)
        {:error, _reason} -> state
      end
    else
      state
    end
  end

  defp advance_elapsed_buckets(%{next_bucket: nil} = state, now) do
    %{state | bucket: WikimediaBucket.new(now)}
  end

  defp advance_elapsed_buckets(%{next_bucket: next_bucket} = state, now) do
    promoted_state = %{state | bucket: next_bucket, next_bucket: nil}

    if WikimediaBucket.elapsed?(next_bucket, now) do
      case persist_bucket(promoted_state, next_bucket) do
        {:ok, persisted_state} -> %{persisted_state | bucket: WikimediaBucket.new(now)}
        {:error, _reason} -> promoted_state
      end
    else
      promoted_state
    end
  end

  defp persist_bucket(state, bucket) do
    started_at = System.monotonic_time()
    successful_at = state.clock.()

    persistence = persist_bucket_contents(state, bucket, successful_at)

    case persistence do
      {:ok, persisted_state, :noop} ->
        {:ok, persisted_state}

      {:ok, persisted_state, count} ->
        record_feed(
          :success,
          System.monotonic_time() - started_at,
          count,
          persisted_state.attempt
        )

        {:ok, persisted_state}

      {:error, _reason} = failure ->
        record_feed(:failure, System.monotonic_time() - started_at, 0, state.attempt)
        failure
    end
  end

  defp persist_bucket_contents(state, bucket, successful_at) do
    case WikimediaBucket.flush(bucket) do
      bucket_payload when is_map(bucket_payload) ->
        with {:ok, event} <- Normalizer.wikimedia_bucket(bucket_payload),
             last_event_at <- DateTime.to_iso8601(bucket.window_start),
             :ok <-
               state.buffer.(
                 [event],
                 checkpoint(state, state.latest_cursor, successful_at, last_event_at)
               ) do
          {:ok,
           %{
             state
             | cursor: state.latest_cursor,
               last_event_at: last_event_at
           }, 1}
        end

      :empty ->
        persist_empty_bucket(state, bucket, successful_at)
    end
  end

  defp persist_empty_bucket(%{cursor: cursor} = state, %{cursor: cursor}, _successful_at),
    do: {:ok, state, :noop}

  defp persist_empty_bucket(state, %{cursor: nil}, _successful_at),
    do: {:ok, state, :noop}

  defp persist_empty_bucket(state, bucket, successful_at) do
    case state.buffer.(
           [],
           checkpoint(state, bucket.cursor, successful_at, state.last_event_at)
         ) do
      :ok ->
        {:ok,
         %{
           state
           | cursor: bucket.cursor
         }, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp checkpoint(_state, cursor, successful_at, last_event_at) do
    %{
      source: @source,
      cursor: cursor,
      etag: nil,
      last_successful_at: successful_at,
      metadata: %{"last_event_at" => last_event_at}
    }
  end

  defp schedule_reconnect(state) do
    delay = Backoff.delay(state.attempt, state.random.())
    attempt = state.attempt + 1

    Telemetry.record_retry(:wikimedia, :connection, attempt: attempt, delay: delay)
    state.timer.(self(), :connect, delay)
    %{state | attempt: attempt}
  end

  defp record_feed(status, duration, count, attempt) do
    Telemetry.record_feed(:wikimedia, status,
      duration: duration,
      count: count,
      attempt: attempt
    )
  end

  defp clear_stream(state), do: %{state | stream_pid: nil, stream_monitor: nil}
  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
