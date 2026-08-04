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
  @contact_checkpoint_interval 30

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
      last_contact_checkpoint_at: checkpoint && checkpoint.last_successful_at,
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
    now = state.clock.() |> DateTime.truncate(:second)
    updated_state = maybe_flush_elapsed_bucket(state, now)
    updated_state.timer.(self(), :flush_bucket, @flush_interval)
    {:noreply, updated_state}
  end

  @impl true
  def handle_call({:frame, frame}, _from, state) do
    case WikimediaBucket.add(state.bucket, frame) do
      {:ok, bucket} ->
        {:reply, :ok, %{state | bucket: bucket, attempt: 0}}

      {:flush, completed_bucket, next_bucket} ->
        case persist_bucket(state, completed_bucket) do
          {:ok, persisted_state} ->
            {:reply, :ok, %{persisted_state | bucket: next_bucket, attempt: 0}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:heartbeat, bucket} ->
        persist_heartbeat(%{state | bucket: bucket, attempt: 0})

      {:drop, _reason, bucket} ->
        {:reply, :ok, %{state | bucket: bucket}}
    end
  end

  defp persist_heartbeat(state) do
    now = state.clock.()

    if contact_checkpoint_due?(state.last_contact_checkpoint_at, now) do
      checkpoint = checkpoint(state, state.bucket.cursor, now, state.last_event_at)

      case state.buffer.([], checkpoint) do
        :ok ->
          record_feed(:success, 0, 0, state.attempt)

          {:reply, :ok,
           %{state | cursor: state.bucket.cursor, last_contact_checkpoint_at: now, attempt: 0}}

        {:error, reason} ->
          record_feed(:failure, 0, 0, state.attempt)
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  defp maybe_flush_elapsed_bucket(state, now) do
    if state.bucket.count > 0 and DateTime.compare(state.bucket.second, now) == :lt do
      case persist_bucket(state, state.bucket) do
        {:ok, persisted_state} -> %{persisted_state | bucket: WikimediaBucket.new(now)}
        {:error, _reason} -> state
      end
    else
      state
    end
  end

  defp persist_bucket(state, bucket) do
    started_at = System.monotonic_time()
    successful_at = state.clock.()

    persistence =
      with bucket_payload when is_map(bucket_payload) <- WikimediaBucket.flush(bucket),
           {:ok, event} <- Normalizer.wikimedia_bucket(bucket_payload),
           last_event_at <- DateTime.to_iso8601(bucket.second),
           :ok <-
             state.buffer.(
               [event],
               checkpoint(state, bucket.cursor, successful_at, last_event_at)
             ) do
        {:ok,
         %{
           state
           | cursor: bucket.cursor,
             last_contact_checkpoint_at: successful_at,
             last_event_at: DateTime.to_iso8601(bucket.second)
         }}
      else
        :empty -> {:ok, state}
        {:error, reason} -> {:error, reason}
        _failure -> {:error, :invalid_bucket}
      end

    case persistence do
      {:ok, persisted_state} = success ->
        record_feed(
          :success,
          System.monotonic_time() - started_at,
          1,
          persisted_state.attempt
        )

        success

      {:error, _reason} = failure ->
        record_feed(:failure, System.monotonic_time() - started_at, 0, state.attempt)
        failure
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

  defp contact_checkpoint_due?(nil, _now), do: true

  defp contact_checkpoint_due?(last_checkpoint_at, now) do
    DateTime.diff(now, last_checkpoint_at, :second) >= @contact_checkpoint_interval
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
