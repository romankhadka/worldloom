defmodule Worldloom.Loom.TimelineProjectionTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.Event
  alias Worldloom.Loom.TimelineProjection

  @sources ~w(wikimedia bluesky ripe_ris solana drand visitor usgs)
  @start_at ~U[2026-08-09 12:00:00.000000Z]

  test "spreads dense sources across the interval and balances the final projection" do
    events =
      @sources
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {source, source_index} ->
        for offset <- 0..149 do
          event(source, source_index * 1_000 + offset, offset)
        end
      end)

    projected = TimelineProjection.select(events)

    assert length(projected) == 600
    assert projected == Enum.sort_by(projected, &{&1.occurred_at, &1.id})
    assert MapSet.new(projected, & &1.source) == MapSet.new(@sources)

    for source <- @sources do
      source_events = Enum.filter(projected, &(&1.source == source))

      assert Enum.min_by(source_events, &{&1.occurred_at, &1.id}).occurred_at == @start_at

      assert Enum.max_by(source_events, &{&1.occurred_at, &1.id}).occurred_at ==
               DateTime.add(@start_at, 149, :second)
    end
  end

  test "keeps sparse sources beside a dense source" do
    dense = for offset <- 0..999, do: event("wikimedia", 10_000 + offset, offset)
    earthquake = event("usgs", 20_000, 450)
    visitor = event("visitor", 20_001, 451)

    projected = TimelineProjection.select(dense ++ [earthquake, visitor])

    assert length(projected) <= 600
    assert earthquake in projected
    assert visitor in projected
  end

  test "force-includes a trusted same-source anchor after temporal sampling" do
    events = for offset <- 0..999, do: event("visitor", 30_000 + offset, offset)
    anchor = Enum.at(events, 451)

    projected = TimelineProjection.select(events, anchor)

    assert length(projected) == 100
    assert anchor in projected
    assert hd(projected) == hd(events)
    assert List.last(projected) == List.last(events)
  end

  test "weather is ambient rather than projected topology" do
    weather = event("open_meteo", 40_000, 10)

    assert TimelineProjection.select([weather]) == []
  end

  test "selection is deterministic across input order and duplicates" do
    events =
      for offset <- 0..699 do
        source = Enum.at(@sources, rem(offset, length(@sources)))
        event(source, 50_000 + offset, offset)
      end

    expected = TimelineProjection.select(events)

    assert TimelineProjection.select(Enum.reverse(events) ++ Enum.take(events, 20)) == expected
  end

  defp event(source, id, offset) do
    %Event{
      id: id,
      kind: kind(source),
      source: source,
      external_id: "#{source}:#{id}",
      occurred_at: DateTime.add(@start_at, offset, :second),
      render_version: render_version(source),
      render_seed: id,
      lane: 0.5,
      intensity: 0.6,
      payload: %{"summary" => "Projected #{source} event #{id}"},
      inserted_at: @start_at
    }
  end

  defp kind("wikimedia"), do: "wikimedia"
  defp kind("bluesky"), do: "public_activity"
  defp kind("ripe_ris"), do: "route_change"
  defp kind("solana"), do: "slot"
  defp kind("drand"), do: "randomness"
  defp kind("visitor"), do: "illuminate"
  defp kind("usgs"), do: "earthquake"
  defp kind("open_meteo"), do: "weather"

  defp render_version(source) when source in ~w(bluesky ripe_ris solana drand), do: 2
  defp render_version(_source), do: 1
end
