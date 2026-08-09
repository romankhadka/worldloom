defmodule Worldloom.Signals.Buffer do
  use GenServer

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.Merger
  alias WorldloomWeb.Telemetry

  @call_timeout :infinity
  @drain_interval 250
  @maximum_depth 64
  @maximum_partition_depth 16
  @maximum_drand_depth 20
  @retry_delays [250, 1_000, 5_000]
  @uint32_max 4_294_967_295
  @ordinary_sources [:wikimedia, :usgs, :open_meteo, :bluesky, :ripe_ris, :solana]
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
      partitions: %{},
      rotation: :queue.new(),
      blocked_until: %{},
      depth: 0,
      timer_ref: nil,
      coordinator: Keyword.get(options, :coordinator, Coordinator),
      merger: Keyword.get(options, :merger, Merger),
      health_registry: Keyword.get(options, :health_registry, HealthRegistry),
      clock: Keyword.get(options, :clock, &default_clock/0),
      timer: Keyword.get(options, :timer, &default_timer/3)
    }

    GenServer.start_link(__MODULE__, state, registration_options(name))
  end

  @spec submit(GenServer.server(), [SourceEvent.t()], map()) ::
          :ok | {:error, :invalid_submission | :persistence_unavailable | :capacity}
  def submit(server \\ __MODULE__, events, checkpoint),
    do: GenServer.call(server, {:submit, events, checkpoint}, @call_timeout)

  @spec depth(GenServer.server()) :: non_neg_integer()
  def depth(server \\ __MODULE__), do: GenServer.call(server, :depth)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:submit, events, checkpoint}, from, state) do
    case submission_entries(events, checkpoint, from) do
      {:ok, entries} -> admit(entries, state)
      {:error, :invalid_submission} -> {:reply, {:error, :invalid_submission}, state}
    end
  end

  def handle_call(:depth, _from, state), do: {:reply, state.depth, state}

  @impl true
  def handle_info({:drain, token}, %{timer_ref: %{token: token}} = state) do
    drain(%{state | timer_ref: nil})
  end

  def handle_info({:drain, _stale_token}, state), do: {:noreply, state}
  def handle_info(:drain, state), do: drain(%{state | timer_ref: nil})

  defp admit(entries, state) do
    source = entries |> List.first() |> Map.fetch!(:source)

    case enqueue_all(state, entries, source) do
      {:ok, enqueued_state, merge_counts, affected_sources} ->
        observed_state =
          Enum.reduce(merge_counts, enqueued_state, fn {merged_source, eliminated}, current ->
            record_health(current, merged_source, {:merge, min(eliminated, @uint32_max)})
          end)

        updated_state =
          observed_state
          |> emit_depths(affected_sources)
          |> schedule_if_needed(@drain_interval)

        {:noreply, updated_state}

      {:error, :capacity} ->
        record_health(state, source, {:drop, :capacity})
        {:reply, {:error, :capacity}, state}
    end
  end

  defp enqueue_all(state, entries, source) do
    candidate = Enum.reduce(entries, state, &enqueue_raw(&2, &1))

    with {:ok, partitioned, partition_merges, partition_sources} <-
           compact_to_partition_limit(candidate, source),
         {:ok, bounded, global_merges, global_sources} <-
           compact_to_global_limit(partitioned, source) do
      merge_counts =
        Map.merge(partition_merges, global_merges, fn _source, left, right -> left + right end)

      affected_sources =
        [source | partition_sources ++ global_sources]
        |> Enum.uniq()

      {:ok, bounded, merge_counts, affected_sources}
    else
      {:error, :capacity} -> {:error, :capacity}
    end
  end

  defp enqueue_raw(state, entry) do
    partition = Map.get(state.partitions, entry.source, :queue.new())
    empty? = :queue.is_empty(partition)
    updated_partition = :queue.in(entry, partition)

    %{
      state
      | partitions: Map.put(state.partitions, entry.source, updated_partition),
        rotation: if(empty?, do: :queue.in(entry.source, state.rotation), else: state.rotation),
        depth: state.depth + 1
    }
  end

  defp compact_to_partition_limit(state, :drand) do
    if partition_depth(state, :drand) <= @maximum_drand_depth do
      {:ok, state, %{}, []}
    else
      {:error, :capacity}
    end
  end

  defp compact_to_partition_limit(state, source) do
    compact_source_until(state, source, @maximum_partition_depth, %{}, [])
  end

  defp compact_source_until(state, source, limit, merge_counts, affected_sources) do
    if partition_depth(state, source) <= limit do
      {:ok, state, merge_counts, affected_sources}
    else
      case compact_source_once(state, source) do
        {:ok, compacted, eliminated} ->
          compact_source_until(
            compacted,
            source,
            limit,
            Map.update(merge_counts, source, eliminated, &(&1 + eliminated)),
            [source | affected_sources]
          )

        :not_compactable ->
          {:error, :capacity}
      end
    end
  end

  defp compact_to_global_limit(state, preferred_source) do
    compact_global(state, preferred_source, %{}, [])
  end

  defp compact_global(%{depth: depth} = state, _preferred_source, merge_counts, affected_sources)
       when depth <= @maximum_depth do
    {:ok, state, merge_counts, affected_sources}
  end

  defp compact_global(state, preferred_source, merge_counts, affected_sources) do
    sources = Enum.uniq([preferred_source | @ordinary_sources])

    case compact_first_available(state, sources) do
      {:ok, compacted, source, eliminated} ->
        compact_global(
          compacted,
          preferred_source,
          Map.update(merge_counts, source, eliminated, &(&1 + eliminated)),
          [source | affected_sources]
        )

      :not_compactable ->
        {:error, :capacity}
    end
  end

  defp compact_first_available(_state, []), do: :not_compactable

  defp compact_first_available(state, [source | sources]) do
    case compact_source_once(state, source) do
      {:ok, compacted, eliminated} -> {:ok, compacted, source, eliminated}
      :not_compactable -> compact_first_available(state, sources)
    end
  end

  defp compact_source_once(state, source) do
    entries = state.partitions |> Map.get(source, :queue.new()) |> :queue.to_list()

    case compact_entries(entries, state.merger, []) do
      {:ok, compacted_entries, eliminated} ->
        {:ok,
         %{
           state
           | partitions: Map.put(state.partitions, source, :queue.from_list(compacted_entries)),
             depth: state.depth - eliminated
         }, eliminated}

      :not_compactable ->
        :not_compactable
    end
  end

  defp compact_entries([], _merger, _prefix), do: :not_compactable

  defp compact_entries([entry | remaining], merger, prefix) do
    case compactable_type(entry) do
      nil ->
        compact_entries(remaining, merger, [entry | prefix])

      type ->
        {run_tail, suffix} =
          Enum.split_while(remaining, &(compactable_type(&1) == type))

        run = [entry | run_tail]

        if length(run) >= 2 do
          case compact_run(run, type, merger) do
            {:ok, compacted_entry} ->
              {:ok, Enum.reverse(prefix) ++ [compacted_entry | suffix], length(run) - 1}

            :not_compactable ->
              compact_entries(suffix, merger, Enum.reduce(run, prefix, &[&1 | &2]))
          end
        else
          compact_entries(suffix, merger, [entry | prefix])
        end
    end
  end

  defp compactable_type(%{attempts: 0, events: []}), do: :checkpoint
  defp compactable_type(%{attempts: 0, events: [_event | _events]}), do: :events
  defp compactable_type(_entry), do: nil

  defp compact_run(entries, :checkpoint, _merger),
    do: {:ok, compacted_entry(entries, [])}

  defp compact_run(entries, :events, merger) do
    events = Enum.flat_map(entries, & &1.events)

    case merger.merge(events) do
      {:ok, merged_event} -> {:ok, compacted_entry(entries, [merged_event])}
      {:error, _reason} -> :not_compactable
    end
  end

  defp compacted_entry(entries, events) do
    %{
      source: entries |> List.first() |> Map.fetch!(:source),
      events: events,
      checkpoint: latest_checkpoint(entries),
      waiters: Enum.flat_map(entries, & &1.waiters),
      attempts: 0
    }
  end

  defp drain(%{depth: 0} = state), do: {:noreply, %{state | timer_ref: nil}}

  defp drain(state) do
    now = monotonic_now(state)

    case take_ready_source(state.rotation, state.blocked_until, now) do
      {:none, rotation} ->
        {:noreply,
         state
         |> Map.put(:rotation, rotation)
         |> schedule_if_needed(@drain_interval)}

      {:ok, source, rotation} ->
        partition = Map.fetch!(state.partitions, source)
        {{:value, entry}, remaining_partition} = :queue.out(partition)
        selected_state = %{state | rotation: rotation}

        case Coordinator.commit_external(
               selected_state.coordinator,
               entry.events,
               entry.checkpoint
             ) do
          {:ok, _inserted_events} ->
            reply_waiters(entry.waiters, :ok)

            updated_state =
              selected_state
              |> complete_entry(source, remaining_partition)
              |> emit_depth(source)
              |> schedule_if_needed(@drain_interval)

            {:noreply, updated_state}

          {:error, _reason} ->
            retry_or_fail(entry, remaining_partition, source, selected_state)
        end
    end
  end

  defp take_ready_source(rotation, blocked_until, now) do
    take_ready_source(rotation, blocked_until, now, :queue.len(rotation))
  end

  defp take_ready_source(rotation, _blocked_until, _now, 0), do: {:none, rotation}

  defp take_ready_source(rotation, blocked_until, now, sources_left) do
    {{:value, source}, remaining} = :queue.out(rotation)

    if ready?(blocked_until, source, now) do
      {:ok, source, remaining}
    else
      take_ready_source(:queue.in(source, remaining), blocked_until, now, sources_left - 1)
    end
  end

  defp ready?(blocked_until, source, now) do
    case Map.fetch(blocked_until, source) do
      :error -> true
      {:ok, deadline} -> deadline <= now
    end
  end

  defp complete_entry(state, source, remaining_partition) do
    {partitions, rotation} =
      if :queue.is_empty(remaining_partition) do
        {Map.delete(state.partitions, source), state.rotation}
      else
        {Map.put(state.partitions, source, remaining_partition),
         :queue.in(source, state.rotation)}
      end

    %{
      state
      | partitions: partitions,
        rotation: rotation,
        blocked_until: Map.delete(state.blocked_until, source),
        depth: state.depth - 1
    }
  end

  defp retry_or_fail(entry, remaining_partition, source, state) do
    case Enum.at(@retry_delays, entry.attempts) do
      nil ->
        failed_entries = [entry | :queue.to_list(remaining_partition)]

        failed_entries
        |> Enum.flat_map(& &1.waiters)
        |> reply_waiters({:error, :persistence_unavailable})

        updated_state =
          state
          |> Map.put(:partitions, Map.delete(state.partitions, source))
          |> Map.put(:blocked_until, Map.delete(state.blocked_until, source))
          |> Map.put(:depth, state.depth - length(failed_entries))
          |> emit_depth(source)
          |> schedule_if_needed(@drain_interval)

        {:noreply, updated_state}

      retry_delay ->
        retry_entry = %{entry | attempts: entry.attempts + 1}
        retry_partition = :queue.in_r(retry_entry, remaining_partition)

        Telemetry.record_retry(source, :persistence,
          attempt: retry_entry.attempts,
          delay: retry_delay
        )

        updated_state =
          state
          |> Map.put(:partitions, Map.put(state.partitions, source, retry_partition))
          |> Map.put(:rotation, :queue.in(source, state.rotation))
          |> Map.put(
            :blocked_until,
            Map.put(state.blocked_until, source, monotonic_now(state) + retry_delay)
          )
          |> record_health(source, {:retry, 1})
          |> emit_depth(source)
          |> schedule_if_needed(@drain_interval)

        {:noreply, updated_state}
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

  defp latest_checkpoint(entries) do
    Enum.reduce(entries, nil, fn entry, checkpoint -> entry.checkpoint || checkpoint end)
  end

  defp reply_waiters(waiters, reply), do: Enum.each(waiters, &GenServer.reply(&1, reply))

  defp schedule_if_needed(%{depth: 0} = state, _delay), do: %{state | timer_ref: nil}

  defp schedule_if_needed(state, minimum_delay) do
    now = monotonic_now(state)
    delay = next_delay(state, now, minimum_delay)
    due_at = now + delay

    case state.timer_ref do
      %{due_at: current_due_at} when current_due_at <= due_at -> state
      _missing_or_later -> schedule(state, delay, due_at)
    end
  end

  defp next_delay(state, now, minimum_delay) do
    sources = :queue.to_list(state.rotation)

    if Enum.any?(sources, &ready?(state.blocked_until, &1, now)) do
      minimum_delay
    else
      earliest_unblock =
        sources
        |> Enum.map(&Map.fetch!(state.blocked_until, &1))
        |> Enum.min()

      max(earliest_unblock - now, minimum_delay)
    end
  end

  defp schedule(state, delay, due_at) do
    token = make_ref()
    reference = state.timer.(self(), {:drain, token}, delay)
    %{state | timer_ref: %{token: token, reference: reference, due_at: due_at}}
  end

  defp emit_depths(state, sources), do: Enum.reduce(sources, state, &emit_depth(&2, &1))

  defp emit_depth(state, source) do
    Telemetry.record_buffer_depth(
      source,
      state.depth,
      partition_depth(state, source),
      monotonic_now(state)
    )

    state
  end

  defp record_health(state, source, observation) do
    :ok = HealthRegistry.record(state.health_registry, source, observation)
    state
  end

  defp partition_depth(state, source) do
    state.partitions |> Map.get(source, :queue.new()) |> :queue.len()
  end

  defp monotonic_now(state) do
    case state.clock.() do
      milliseconds when is_integer(milliseconds) -> milliseconds
      _invalid -> raise ArgumentError, "buffer clock must return monotonic integer milliseconds"
    end
  end

  defp checkpoint_source(checkpoint), do: checkpoint[:source] || checkpoint["source"]
  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
  defp default_clock, do: System.monotonic_time(:millisecond)
  defp default_timer(process, message, delay), do: Process.send_after(process, message, delay)
end
