defmodule Worldloom.Signals.Buffer do
  use GenServer

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Signals.Merger
  alias WorldloomWeb.Telemetry

  @call_timeout :infinity
  @drain_interval 250
  @maximum_depth 16
  @retry_delays [250, 1_000, 5_000]
  @checkpoint_sources %{
    "wikimedia" => :wikimedia,
    "usgs" => :usgs,
    "open_meteo" => :open_meteo,
    "bluesky" => :bluesky,
    "ripe_ris" => :ripe_ris,
    "solana" => :solana,
    "drand" => :drand
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)

    state = %{
      queue: [],
      timer_ref: nil,
      coordinator: Keyword.get(options, :coordinator, Coordinator),
      merger: Keyword.get(options, :merger, Merger),
      clock: Keyword.get(options, :clock, &default_clock/0),
      timer: Keyword.get(options, :timer, &default_timer/3)
    }

    GenServer.start_link(__MODULE__, state, registration_options(name))
  end

  @spec submit(GenServer.server(), [SourceEvent.t()], map()) ::
          :ok | {:error, :invalid_submission | :persistence_unavailable}
  def submit(server \\ __MODULE__, events, checkpoint),
    do: GenServer.call(server, {:submit, events, checkpoint}, @call_timeout)

  @spec depth(GenServer.server()) :: non_neg_integer()
  def depth(server \\ __MODULE__), do: GenServer.call(server, :depth)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:submit, events, checkpoint}, from, state) do
    case submission_entries(events, checkpoint, from) do
      {:ok, entries} ->
        queue = Enum.reduce(entries, state.queue, &enqueue(&2, &1, state.merger))

        updated_state =
          state
          |> Map.put(:queue, queue)
          |> emit_depth()
          |> schedule_if_needed(@drain_interval)

        {:noreply, updated_state}

      {:error, :invalid_submission} ->
        {:reply, {:error, :invalid_submission}, state}
    end
  end

  def handle_call(:depth, _from, state), do: {:reply, length(state.queue), state}

  @impl true
  def handle_info(:drain, %{queue: []} = state) do
    {:noreply, state |> Map.put(:timer_ref, nil) |> emit_depth()}
  end

  def handle_info(:drain, %{queue: [entry | remaining]} = state) do
    state = %{state | timer_ref: nil}

    case Coordinator.commit_external(state.coordinator, entry.events, entry.checkpoint) do
      {:ok, _inserted_events} ->
        reply_waiters(entry.waiters, :ok)

        updated_state =
          state
          |> Map.put(:queue, remaining)
          |> emit_depth()
          |> schedule_if_needed(@drain_interval)

        {:noreply, updated_state}

      {:error, _reason} ->
        retry_or_fail(entry, remaining, state)
    end
  end

  defp submission_entries(events, checkpoint, from)
       when is_list(events) and events != [] and is_map(checkpoint) do
    with {:ok, validated_events} <- validate_events(events),
         [source] <- validated_events |> Enum.map(& &1.source) |> Enum.uniq(),
         true <- source != :visitor,
         true <- checkpoint_source(checkpoint) == Atom.to_string(source) do
      final_index = length(validated_events) - 1

      entries =
        validated_events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} ->
          final? = index == final_index

          %{
            source: source,
            events: [event],
            checkpoint: if(final?, do: checkpoint, else: nil),
            waiters: if(final?, do: [from], else: []),
            attempts: 0
          }
        end)

      {:ok, entries}
    else
      _invalid -> {:error, :invalid_submission}
    end
  end

  defp submission_entries([], checkpoint, from) when is_map(checkpoint) do
    case Map.fetch(@checkpoint_sources, checkpoint_source(checkpoint)) do
      {:ok, source} ->
        {:ok,
         [
           %{
             source: source,
             events: [],
             checkpoint: checkpoint,
             waiters: [from],
             attempts: 0
           }
         ]}

      :error ->
        {:error, :invalid_submission}
    end
  end

  defp submission_entries(_events, _checkpoint, _from), do: {:error, :invalid_submission}

  defp validate_events(events) do
    Enum.reduce_while(events, {:ok, []}, fn
      %SourceEvent{} = event, {:ok, validated_events} ->
        case SourceEvent.new(Map.from_struct(event)) do
          {:ok, validated_event} -> {:cont, {:ok, [validated_event | validated_events]}}
          {:error, _reason} -> {:halt, {:error, :invalid_submission}}
        end

      _event, _validated_events ->
        {:halt, {:error, :invalid_submission}}
    end)
    |> case do
      {:ok, validated_events} -> {:ok, Enum.reverse(validated_events)}
      error -> error
    end
  end

  defp enqueue(queue, entry, _merger) when length(queue) < @maximum_depth,
    do: queue ++ [entry]

  defp enqueue(queue, entry, merger) do
    compacted_queue = compact_for_space(queue, entry.source, merger)
    compacted_queue ++ [entry]
  end

  defp compact_for_space(queue, preferred_source, merger) do
    source =
      if Enum.count(queue, &(&1.source == preferred_source)) >= 2 do
        preferred_source
      else
        queue
        |> Enum.frequencies_by(& &1.source)
        |> Enum.find_value(fn {source, count} -> if count >= 2, do: source end)
      end

    compact_source(queue, source, merger)
  end

  defp compact_source(queue, source, merger) do
    matching_entries = Enum.filter(queue, &(&1.source == source))
    source_events = Enum.flat_map(matching_entries, & &1.events)

    compacted_events =
      case source_events do
        [] ->
          []

        [event] ->
          [event]

        events ->
          {:ok, merged_event} = merger.merge(events)
          [merged_event]
      end

    compacted_entry = %{
      source: source,
      events: compacted_events,
      checkpoint: latest_checkpoint(matching_entries),
      waiters: Enum.flat_map(matching_entries, & &1.waiters),
      attempts: matching_entries |> Enum.map(& &1.attempts) |> Enum.max()
    }

    replace_matching_entries(queue, source, compacted_entry)
  end

  defp replace_matching_entries(queue, source, merged_entry) do
    {rebuilt, inserted?} =
      Enum.reduce(queue, {[], false}, fn queued_entry, {rebuilt, inserted?} ->
        cond do
          queued_entry.source != source ->
            {[queued_entry | rebuilt], inserted?}

          not inserted? ->
            {[merged_entry | rebuilt], true}

          true ->
            {rebuilt, true}
        end
      end)

    if inserted? do
      Enum.reverse(rebuilt)
    else
      Enum.reverse([merged_entry | rebuilt])
    end
  end

  defp latest_checkpoint(entries) do
    Enum.reduce(entries, nil, fn entry, checkpoint -> entry.checkpoint || checkpoint end)
  end

  defp retry_or_fail(entry, remaining, state) do
    case Enum.at(@retry_delays, entry.attempts) do
      nil ->
        {aborted_entries, retained_entries} =
          Enum.split_with(remaining, &(&1.source == entry.source))

        [entry | aborted_entries]
        |> Enum.flat_map(& &1.waiters)
        |> reply_waiters({:error, :persistence_unavailable})

        updated_state =
          state
          |> Map.put(:queue, retained_entries)
          |> emit_depth()
          |> schedule_if_needed(@drain_interval)

        {:noreply, updated_state}

      retry_delay ->
        retry_entry = %{entry | attempts: entry.attempts + 1}

        Telemetry.record_retry(entry.source, :persistence,
          attempt: retry_entry.attempts,
          delay: retry_delay
        )

        updated_state =
          state
          |> Map.put(:queue, [retry_entry | remaining])
          |> emit_depth()
          |> schedule(retry_delay)

        {:noreply, updated_state}
    end
  end

  defp reply_waiters(waiters, reply) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end

  defp schedule_if_needed(%{queue: [], timer_ref: nil} = state, _delay), do: state
  defp schedule_if_needed(%{timer_ref: nil} = state, delay), do: schedule(state, delay)
  defp schedule_if_needed(state, _delay), do: state

  defp schedule(state, delay) do
    %{state | timer_ref: state.timer.(self(), :drain, delay)}
  end

  defp emit_depth(state) do
    :telemetry.execute(
      [:worldloom, :signals, :buffer, :depth],
      %{depth: length(state.queue), observed_at: state.clock.()},
      %{}
    )

    state
  end

  defp checkpoint_source(checkpoint), do: checkpoint[:source] || checkpoint["source"]
  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
  defp default_clock, do: System.monotonic_time(:millisecond)
  defp default_timer(process, message, delay), do: Process.send_after(process, message, delay)
end
