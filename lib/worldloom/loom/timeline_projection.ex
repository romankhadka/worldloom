defmodule Worldloom.Loom.TimelineProjection do
  alias Worldloom.Loom.Event

  @maximum_events 600
  @per_source_candidates 100

  @spec select([Event.t()], Event.t() | nil) :: [Event.t()]
  def select(events, anchor \\ nil) when is_list(events) do
    events
    |> Enum.filter(&topology_event?/1)
    |> maybe_add_anchor(anchor)
    |> Enum.uniq_by(& &1.id)
    |> Enum.group_by(& &1.source)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&source_queue(&1, anchor))
    |> round_robin(@maximum_events)
    |> Enum.sort_by(&{&1.occurred_at, &1.id})
  end

  defp topology_event?(%Event{source: source}), do: source != "open_meteo"
  defp topology_event?(_event), do: false

  defp maybe_add_anchor(events, %Event{source: source} = anchor)
       when source != "open_meteo",
       do: [anchor | events]

  defp maybe_add_anchor(events, _anchor), do: events

  defp source_queue({source, source_events}, anchor) do
    ordered = Enum.sort_by(source_events, &{&1.occurred_at, &1.id})

    spread =
      ordered
      |> evenly_spaced(@per_source_candidates)
      |> ensure_anchor(ordered, anchor)
      |> Enum.sort_by(&{&1.occurred_at, &1.id})
      |> temporal_priority(anchor)

    {source, spread}
  end

  defp evenly_spaced(events, limit) when length(events) <= limit, do: events

  defp evenly_spaced(events, limit) do
    last_index = length(events) - 1

    0..(limit - 1)
    |> Enum.map(&round(&1 * last_index / (limit - 1)))
    |> Enum.uniq()
    |> Enum.map(&Enum.at(events, &1))
  end

  defp ensure_anchor(sampled, source_events, %Event{} = anchor) do
    source_has_anchor? = Enum.any?(source_events, &(&1.id == anchor.id))
    sample_has_anchor? = Enum.any?(sampled, &(&1.id == anchor.id))

    if source_has_anchor? and not sample_has_anchor? do
      replace_nearest_non_endpoint(sampled, anchor)
    else
      sampled
    end
  end

  defp ensure_anchor(sampled, _source_events, _anchor), do: sampled

  defp replace_nearest_non_endpoint([_only] = sampled, _anchor), do: sampled
  defp replace_nearest_non_endpoint([_first, _last] = sampled, _anchor), do: sampled

  defp replace_nearest_non_endpoint(sampled, anchor) do
    last_index = length(sampled) - 1

    {_event, replace_index} =
      sampled
      |> Enum.with_index()
      |> Enum.reject(fn {_event, index} -> index in [0, last_index] end)
      |> Enum.min_by(fn {event, _index} ->
        abs(DateTime.diff(event.occurred_at, anchor.occurred_at, :microsecond))
      end)

    List.replace_at(sampled, replace_index, anchor)
  end

  defp temporal_priority([], _anchor), do: []

  defp temporal_priority(events, anchor) do
    last_index = length(events) - 1

    anchor_index =
      if is_struct(anchor, Event) do
        Enum.find_index(events, &(&1.id == anchor.id))
      end

    [0, last_index, anchor_index | midpoint_indices(1, last_index - 1)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&Enum.at(events, &1))
  end

  defp midpoint_indices(first, last) when first > last, do: []

  defp midpoint_indices(first, last) do
    midpoint = div(first + last, 2)

    [
      midpoint
      | interleave(
          midpoint_indices(first, midpoint - 1),
          midpoint_indices(midpoint + 1, last)
        )
    ]
  end

  defp interleave([], right), do: right
  defp interleave(left, []), do: left

  defp interleave([left | left_rest], [right | right_rest]),
    do: [left, right | interleave(left_rest, right_rest)]

  defp round_robin(source_queues, limit) do
    sources = Enum.map(source_queues, &elem(&1, 0))
    queues = Map.new(source_queues)

    queues
    |> take_round(sources, [], 0, limit)
    |> elem(0)
  end

  defp take_round(queues, sources, selected, selected_count, limit) do
    {next_queues, next_selected, next_count, events_taken} =
      Enum.reduce_while(sources, {queues, selected, selected_count, 0}, fn source,
                                                                           {source_queues, chosen,
                                                                            count, taken} ->
        if count == limit do
          {:halt, {source_queues, chosen, count, taken}}
        else
          case Map.fetch!(source_queues, source) do
            [event | remaining] ->
              {:cont,
               {Map.put(source_queues, source, remaining), [event | chosen], count + 1, taken + 1}}

            [] ->
              {:cont, {source_queues, chosen, count, taken}}
          end
        end
      end)

    if next_count == limit or events_taken == 0 do
      {next_selected, next_queues}
    else
      take_round(next_queues, sources, next_selected, next_count, limit)
    end
  end
end
