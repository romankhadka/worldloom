defmodule Worldloom.Loom.LiveProjection do
  alias Worldloom.Loom.Event
  alias Worldloom.Loom.LiveSnapshot

  @window_seconds 60
  @display_limit 600
  @per_source_limit 240
  @memory_seconds 24 * 60 * 60

  @spec build([Event.t()], Event.t() | nil, non_neg_integer(), DateTime.t() | nil) ::
          LiveSnapshot.t()
  def build(candidates, ambient, commit_watermark, previous_window_end \\ nil) do
    primary_candidates = Enum.reject(candidates, &weather?/1)

    case projection_window_end(primary_candidates, previous_window_end) do
      nil ->
        snapshot(nil, commit_watermark, [], [], ambient)

      window_end ->
        display_events = select_display_events(primary_candidates, window_end)
        memory_events = select_memory_events(primary_candidates, window_end)

        snapshot(window_end, commit_watermark, display_events, memory_events, ambient)
    end
  end

  defp projection_window_end([], previous_window_end), do: previous_window_end

  defp projection_window_end(primary_candidates, previous_window_end) do
    latest_occurrence =
      primary_candidates
      |> Enum.map(& &1.occurred_at)
      |> Enum.reduce(&later_datetime/2)
      |> DateTime.truncate(:second)

    later_datetime(latest_occurrence, previous_window_end)
  end

  defp later_datetime(left, nil), do: left

  defp later_datetime(left, right) do
    case DateTime.compare(left, right) do
      :lt -> right
      :eq -> left
      :gt -> left
    end
  end

  defp select_display_events(primary_candidates, window_end) do
    window_start = DateTime.add(window_end, -@window_seconds, :second)

    primary_candidates
    |> Enum.filter(&within_window?(&1.occurred_at, window_start, window_end))
    |> source_queues()
    |> round_robin()
    |> Enum.sort_by(&{DateTime.to_unix(&1.occurred_at, :microsecond), &1.id})
  end

  defp within_window?(occurred_at, window_start, window_end) do
    DateTime.compare(occurred_at, window_start) != :lt and
      DateTime.compare(occurred_at, window_end) != :gt
  end

  defp source_queues(display_candidates) do
    display_candidates
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {source, events} ->
      {source, events |> Enum.sort(&newer_event_first?/2) |> Enum.take(@per_source_limit)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp round_robin(source_queues) do
    sources = Enum.map(source_queues, &elem(&1, 0))
    queues = Map.new(source_queues)

    queues
    |> take_round(sources, [], 0)
    |> elem(0)
  end

  defp take_round(queues, sources, selected, selected_count) do
    {next_queues, next_selected, next_count, events_taken} =
      Enum.reduce_while(sources, {queues, selected, selected_count, 0}, fn source,
                                                                           {queues, selected,
                                                                            count, taken} ->
        if count == @display_limit do
          {:halt, {queues, selected, count, taken}}
        else
          case Map.fetch!(queues, source) do
            [event | remaining] ->
              {:cont,
               {Map.put(queues, source, remaining), [event | selected], count + 1, taken + 1}}

            [] ->
              {:cont, {queues, selected, count, taken}}
          end
        end
      end)

    if next_count == @display_limit or events_taken == 0 do
      {next_selected, next_queues}
    else
      take_round(next_queues, sources, next_selected, next_count)
    end
  end

  defp select_memory_events(primary_candidates, window_end) do
    minute_start = DateTime.add(window_end, -@window_seconds, :second)
    memory_start = DateTime.add(window_end, -@memory_seconds, :second)

    contextual_candidates =
      primary_candidates
      |> Enum.filter(fn event ->
        DateTime.compare(event.occurred_at, minute_start) == :lt and
          DateTime.compare(event.occurred_at, memory_start) != :lt
      end)
      |> Enum.sort(&newer_event_first?/2)

    earthquake = Enum.find(contextual_candidates, &earthquake?/1)
    visitors = contextual_candidates |> Enum.filter(&visitor?/1) |> Enum.take(3)

    List.wrap(earthquake) ++ visitors
  end

  defp newer_event_first?(left, right) do
    case DateTime.compare(left.occurred_at, right.occurred_at) do
      :lt -> false
      :eq -> left.id >= right.id
      :gt -> true
    end
  end

  defp weather?(%Event{kind: "weather"}), do: true
  defp weather?(%Event{source: "open_meteo"}), do: true
  defp weather?(%Event{}), do: false

  defp earthquake?(%Event{kind: "earthquake", source: "usgs"}), do: true
  defp earthquake?(%Event{}), do: false

  defp visitor?(%Event{source: "visitor"}), do: true
  defp visitor?(%Event{}), do: false

  defp snapshot(window_end, commit_watermark, display_events, memory_events, ambient) do
    %LiveSnapshot{
      window_end: window_end,
      commit_watermark: commit_watermark,
      display_events: display_events,
      memory_events: memory_events,
      ambient: ambient
    }
  end
end
