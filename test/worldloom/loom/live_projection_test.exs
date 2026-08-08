defmodule Worldloom.Loom.LiveProjectionTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.Event
  alias Worldloom.Loom.LiveProjection

  @window_end ~U[2026-08-08 12:01:00Z]

  test "builds the authoritative bounded snapshot envelope" do
    wikimedia = minute_events("wikimedia", 1..300)
    earthquakes = minute_events("usgs", 301..480)
    visitors = minute_events("visitor", 481..660)
    earthquake = event(701, "usgs", ~U[2026-08-08 11:59:59Z])

    contextual_visitors = [
      event(702, "visitor", ~U[2026-08-08 11:59:56Z]),
      event(703, "visitor", ~U[2026-08-08 11:59:57Z]),
      event(704, "visitor", ~U[2026-08-08 11:59:58Z]),
      event(705, "visitor", ~U[2026-08-08 11:59:59Z])
    ]

    visitor_ids = contextual_visitors |> Enum.take(-3) |> Enum.reverse() |> Enum.map(& &1.id)
    weather = event(800, "open_meteo", ~U[2026-08-08 12:30:00Z])

    candidates =
      Enum.reverse(
        wikimedia ++ earthquakes ++ visitors ++ [earthquake | contextual_visitors] ++ [weather]
      )

    snapshot = LiveProjection.build(candidates, weather, 906, ~U[2026-08-08 11:58:00Z])

    assert snapshot.window_end == ~U[2026-08-08 12:01:00Z]
    assert snapshot.snapshot_version == 1
    assert snapshot.commit_watermark == 906
    assert length(snapshot.display_events) == 600
    assert Enum.frequencies_by(snapshot.display_events, & &1.source)["wikimedia"] == 240

    assert snapshot.display_events ==
             Enum.sort_by(snapshot.display_events, &{&1.occurred_at, &1.id})

    assert Enum.map(snapshot.memory_events, & &1.id) == [earthquake.id | visitor_ids]
    assert snapshot.ambient.id == weather.id
  end

  test "window end is the later of the truncated primary occurrence and its previous value" do
    fractional_latest = event(1, "wikimedia", ~U[2026-08-08 12:01:00.987654Z])
    later_weather = event(2, "open_meteo", ~U[2026-08-08 13:00:00Z])

    advanced =
      LiveProjection.build(
        [later_weather, fractional_latest],
        later_weather,
        2,
        ~U[2026-08-08 12:00:30Z]
      )

    preserved =
      LiveProjection.build(
        [event(3, "wikimedia", ~U[2026-08-08 12:00:00Z])],
        nil,
        3,
        ~U[2026-08-08 12:02:00Z]
      )

    assert advanced.window_end == ~U[2026-08-08 12:01:00Z]
    assert preserved.window_end == ~U[2026-08-08 12:02:00Z]
  end

  test "display events stay inside the inclusive sixty-second window" do
    at_start = event(1, "wikimedia", ~U[2026-08-08 12:00:00Z])
    at_end = event(2, "visitor", @window_end)
    too_old = event(3, "wikimedia", ~U[2026-08-08 11:59:59.999999Z])

    snapshot = LiveProjection.build([too_old, at_end, at_start], nil, 3)

    assert Enum.map(snapshot.display_events, & &1.id) == [at_start.id, at_end.id]
    refute too_old in snapshot.display_events
  end

  test "round robin consumes deterministic newest-first source queues within both caps" do
    wikimedia = dense_events("wikimedia", 1, 300)
    earthquakes = dense_events("usgs", 1_001, 300)
    visitors = dense_events("visitor", 2_001, 300)

    snapshot =
      LiveProjection.build(Enum.reverse(wikimedia ++ visitors ++ earthquakes), nil, 2_300)

    frequencies = Enum.frequencies_by(snapshot.display_events, & &1.source)

    assert length(snapshot.display_events) == 600
    assert frequencies == %{"usgs" => 200, "visitor" => 200, "wikimedia" => 200}

    assert selected_ids(snapshot, "usgs") == Enum.to_list(1_101..1_300)
    assert selected_ids(snapshot, "visitor") == Enum.to_list(2_101..2_300)
    assert selected_ids(snapshot, "wikimedia") == Enum.to_list(101..300)

    assert snapshot.display_events ==
             Enum.sort_by(
               snapshot.display_events,
               &{DateTime.to_unix(&1.occurred_at, :microsecond), &1.id}
             )
  end

  test "memory contains only recent rows omitted by time in contextual newest-first order" do
    anchor = event(1, "wikimedia", ~U[2026-08-08 12:00:00Z])

    inside_earthquakes =
      Enum.map(1..241, fn index ->
        occurred_at =
          DateTime.add(anchor.occurred_at, -30_000_000 + index * 100_000, :microsecond)

        event(1_000 + index, "usgs", occurred_at)
      end)

    recent_earthquake = event(2_001, "usgs", ~U[2026-08-08 11:58:59Z])
    older_earthquake = event(2_002, "usgs", ~U[2026-08-08 11:58:58Z])

    contextual_visitors = [
      event(3_001, "visitor", ~U[2026-08-08 11:58:56Z]),
      event(3_002, "visitor", ~U[2026-08-08 11:58:57Z]),
      event(3_003, "visitor", ~U[2026-08-08 11:58:58Z]),
      event(3_004, "visitor", ~U[2026-08-08 11:58:59Z])
    ]

    stale_earthquake = event(4_001, "usgs", ~U[2026-08-07 11:59:59Z])
    stale_visitor = event(4_002, "visitor", ~U[2026-08-07 11:59:59Z])
    current_visitor = event(4_003, "visitor", ~U[2026-08-08 11:59:59Z])

    candidates =
      [
        anchor,
        recent_earthquake,
        older_earthquake,
        stale_earthquake,
        stale_visitor,
        current_visitor
        | inside_earthquakes ++ contextual_visitors
      ]

    snapshot = LiveProjection.build(candidates, nil, 4_003)
    omitted_inside_minute = hd(inside_earthquakes)

    assert Enum.map(snapshot.memory_events, & &1.id) == [2_001, 3_004, 3_003, 3_002]
    refute omitted_inside_minute in snapshot.display_events
    refute omitted_inside_minute in snapshot.memory_events
    refute current_visitor in snapshot.memory_events
    refute stale_earthquake in snapshot.memory_events
    refute stale_visitor in snapshot.memory_events
  end

  test "memory includes earthquake and visitor events exactly twenty-four hours old" do
    window_end = ~U[2026-08-08 12:00:00Z]
    memory_boundary = DateTime.add(window_end, -24 * 60 * 60, :second)
    anchor = event(1, "wikimedia", window_end)
    boundary_earthquake = event(2, "usgs", memory_boundary)
    boundary_visitor = event(3, "visitor", memory_boundary)
    stale_earthquake = event(4, "usgs", DateTime.add(memory_boundary, -1, :microsecond))
    stale_visitor = event(5, "visitor", DateTime.add(memory_boundary, -1, :microsecond))

    snapshot =
      LiveProjection.build(
        [stale_visitor, boundary_visitor, anchor, stale_earthquake, boundary_earthquake],
        nil,
        5
      )

    assert Enum.map(snapshot.memory_events, & &1.id) == [
             boundary_earthquake.id,
             boundary_visitor.id
           ]
  end

  test "memory excludes an earthquake older than twenty-four hours" do
    window_end = ~U[2026-08-08 12:00:00Z]
    memory_boundary = DateTime.add(window_end, -24 * 60 * 60, :second)
    anchor = event(1, "wikimedia", window_end)
    stale_earthquake = event(2, "usgs", DateTime.add(memory_boundary, -1, :microsecond))

    snapshot = LiveProjection.build([stale_earthquake, anchor], nil, 2)

    assert snapshot.memory_events == []
  end

  test "weather candidates are ambient only and the supplied ambient wins" do
    candidate_weather = event(1, "open_meteo", ~U[2026-08-08 13:00:00Z])
    supplied_ambient = event(2, "open_meteo", ~U[2026-08-08 11:55:00Z])
    primary = event(3, "wikimedia", ~U[2026-08-08 12:00:00Z])

    snapshot = LiveProjection.build([candidate_weather, primary], supplied_ambient, 3)

    assert snapshot.ambient == supplied_ambient
    assert snapshot.window_end == primary.occurred_at
    assert snapshot.display_events == [primary]
    assert snapshot.memory_events == []
  end

  test "an empty candidate set preserves the prior window while only advancing the watermark" do
    ambient = event(1, "open_meteo", ~U[2026-08-08 11:55:00Z])
    previous_window_end = ~U[2026-08-08 12:00:00Z]

    preserved = LiveProjection.build([], ambient, 42, previous_window_end)
    initially_empty = LiveProjection.build([], nil, 43)

    assert preserved.window_end == previous_window_end
    assert preserved.commit_watermark == 42
    assert preserved.display_events == []
    assert preserved.memory_events == []
    assert preserved.ambient == ambient

    assert initially_empty.window_end == nil
    assert initially_empty.commit_watermark == 43
    assert initially_empty.display_events == []
    assert initially_empty.memory_events == []
  end

  defp minute_events(source, ids) do
    ids
    |> Enum.with_index()
    |> Enum.map(fn {id, index} ->
      event(id, source, DateTime.add(@window_end, -rem(index, 60)))
    end)
  end

  defp dense_events(source, first_id, count) do
    Enum.map(1..count, fn index ->
      occurred_at = DateTime.add(~U[2026-08-08 12:00:00Z], index * 100_000, :microsecond)
      event(first_id + index - 1, source, occurred_at)
    end)
  end

  defp selected_ids(snapshot, source) do
    snapshot.display_events
    |> Enum.filter(&(&1.source == source))
    |> Enum.map(& &1.id)
  end

  defp event(id, source, occurred_at) do
    {kind, external_id} =
      case source do
        "wikimedia" -> {"wikimedia", "revision-#{id}"}
        "usgs" -> {"earthquake", "earthquake-#{id}"}
        "open_meteo" -> {"weather", "weather-#{id}"}
        "visitor" -> {"illuminate", nil}
      end

    %Event{
      id: id,
      kind: kind,
      source: source,
      external_id: external_id,
      occurred_at: occurred_at,
      render_version: 1,
      render_seed: id,
      lane: 0.5,
      intensity: 0.5,
      payload: %{}
    }
  end
end
