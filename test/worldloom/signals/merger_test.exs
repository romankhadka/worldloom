defmodule Worldloom.Signals.MergerTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Signals.Merger

  @uint32_max 4_294_967_295
  @maximum_window_count div(@uint32_max, 4)
  @edit_types ~w(categorize edit external log new)
  @language_buckets ~w(current_1 current_2 current_3 current_4 current_5)

  test "Wikimedia pressure summaries are associative, commutative, and sufficient" do
    events = [
      wikimedia_event(
        1,
        2,
        40,
        %{"current_1" => 2},
        %{"edit" => 2}
      ),
      wikimedia_event(
        2,
        1,
        20,
        %{"current_2" => 1},
        %{"new" => 1}
      ),
      wikimedia_event(
        3,
        3,
        60,
        %{"current_3" => 3},
        %{"new" => 2, "log" => 1}
      ),
      wikimedia_event(
        4,
        2,
        80,
        %{"current_1" => 1, "current_4" => 1},
        %{"edit" => 2}
      )
    ]

    merged = assert_grouping_invariance(events)

    assert merged.kind == :wikimedia
    assert merged.source == :wikimedia
    assert merged.lane == 0.8065
    assert merged.intensity == 0.404

    assert merged.external_id ==
             "merged:211CDED98B5863520F8F1506BCAF4CD1DFC7AB32B898E60939DF73520934527B"

    assert merged.occurred_at == ~U[2026-08-03 12:00:16.000000Z]
    assert merged.payload["count"] == 8
    assert merged.payload["window_count"] == 4
    assert merged.payload["window_span_seconds"] == 16
    assert merged.payload["total_absolute_byte_delta"] == 200

    assert merged.payload["language_buckets"] == %{
             "current_1" => 3,
             "current_2" => 1,
             "current_3" => 3,
             "current_4" => 1,
             "current_5" => 0
           }

    assert merged.payload["edit_types"] == %{
             "categorize" => 0,
             "edit" => 4,
             "external" => 0,
             "log" => 1,
             "new" => 3
           }

    assert merged.payload["dominant_edit_type"] == "edit"
    assert merged.payload["truncated"] == false

    assert merged.payload["summary"] ==
             "Pressure summary: 8 Wikimedia edits across 4 windows (16 seconds)"
  end

  test "Wikimedia complete fixed counters preserve totals and edit dominance" do
    events = [
      wikimedia_event(1, 7, 10, %{"current_1" => 7}, %{"edit" => 4, "new" => 3}),
      wikimedia_event(2, 7, 10, %{"current_2" => 7}, %{"edit" => 4, "new" => 3}),
      wikimedia_event(3, 9, 10, %{"current_3" => 9}, %{"new" => 9}),
      wikimedia_event(4, 9, 10, %{"current_4" => 9}, %{"new" => 9})
    ]

    merged = assert_grouping_invariance(events)

    assert merged.payload["language_buckets"] == %{
             "current_1" => 7,
             "current_2" => 7,
             "current_3" => 9,
             "current_4" => 9,
             "current_5" => 0
           }

    assert merged.payload["dominant_edit_type"] == "new"
    assert merged.payload["edit_types"]["new"] == 24
  end

  test "Bluesky pressure summaries are associative and derive visuals from counters" do
    events = [
      bluesky_event(1, %{original_posts: 2, replies: 1, reposts: 1, creates: 4}),
      bluesky_event(2, %{original_posts: 1, replies: 2, reposts: 0, creates: 3}),
      bluesky_event(3, %{original_posts: 3, replies: 0, reposts: 2, creates: 5}),
      bluesky_event(4, %{original_posts: 1, replies: 1, reposts: 2, creates: 4})
    ]

    merged = assert_grouping_invariance(events)

    assert merged.kind == :public_activity
    assert merged.lane == 0.3993
    assert merged.intensity == 0.4

    assert merged.external_id ==
             "merged:181C5B34263D73FCF8E24F1819738CEEBEDD909C8644F4D84C3E03A246B2229C"

    assert merged.occurred_at == ~U[2026-08-03 12:00:16.000000Z]
    assert merged.payload["window_count"] == 4
    assert merged.payload["window_span_seconds"] == 16
    assert merged.payload["total_actions"] == 16
    assert merged.payload["original_posts"] == 7
    assert merged.payload["replies"] == 4
    assert merged.payload["reposts"] == 5
    assert merged.payload["creates"] == 16
    assert merged.payload["updates"] == 0
    assert merged.payload["deletes"] == 0
    assert merged.payload["truncated"] == false

    assert merged.payload["summary"] ==
             "Pressure summary: 16 Bluesky actions across 4 windows (16 seconds)"
  end

  test "RIPE pressure summaries count per-window observations without claiming global distinctness" do
    events = [
      ripe_event(1, 4, 1, 3, 2, 1, 2),
      ripe_event(2, 3, 2, 4, 1, 1, 2),
      ripe_event(3, 5, 0, 2, 3, 1, 2),
      ripe_event(4, 2, 3, 1, 4, 1, 2)
    ]

    merged = assert_grouping_invariance(events)

    assert merged.kind == :route_change
    assert merged.lane == 0.099
    assert merged.intensity == 0.25

    assert merged.external_id ==
             "merged:2D3F07E179EA19F10BB82B91B7E55D5CE92248D030B5CE619B788C1D190748C7"

    assert merged.occurred_at == ~U[2026-08-03 12:00:16.000000Z]
    assert merged.payload["window_count"] == 4
    assert merged.payload["window_span_seconds"] == 16
    assert merged.payload["announced"] == 14
    assert merged.payload["withdrawn"] == 6
    assert merged.payload["ipv4"] == 10
    assert merged.payload["ipv6"] == 10
    assert merged.payload["collector_observations"] == 4
    assert merged.payload["peer_observations"] == 8
    assert merged.payload["truncated"] == false

    assert merged.payload["summary"] ==
             "Pressure summary: 20 RIPE route changes across 4 windows (16 seconds)"
  end

  test "Solana pressure summaries preserve extrema and never fabricate boundary gaps" do
    events = [
      solana_event(1, 2, 100, 101, 0),
      solana_event(2, 3, 110, 114, 2),
      solana_event(3, 1, 120, 120, 0),
      solana_event(4, 2, 130, 132, 1)
    ]

    merged = assert_grouping_invariance(events)

    assert merged.kind == :slot
    assert merged.lane == 0.6999
    assert merged.intensity == 0.275

    assert merged.external_id ==
             "merged:A5BD7DA1BB646BCF72431F0DA25946C9644034C58221124337B20033533C3EE5"

    assert merged.occurred_at == ~U[2026-08-03 12:00:16.000000Z]
    assert merged.payload["window_count"] == 4
    assert merged.payload["window_span_seconds"] == 16
    assert merged.payload["slot_count"] == 8
    assert merged.payload["first_slot"] == 100
    assert merged.payload["last_slot"] == 132
    assert merged.payload["gap_count"] == 3
    assert merged.payload["truncated"] == false

    assert merged.payload["summary"] ==
             "Pressure summary: 8 Solana slots with 3 gaps across 4 windows (16 seconds)"
  end

  test "every pressure counter and the window span saturate associatively" do
    saturated_events = [
      wikimedia_event(
        1,
        @uint32_max,
        @uint32_max,
        Map.new(@language_buckets, &{&1, @uint32_max}),
        Map.new(@edit_types, &{&1, @uint32_max}),
        true,
        @maximum_window_count
      ),
      wikimedia_event(2, 1, 1, %{"current_1" => 1}, %{"edit" => 1})
    ]

    wikimedia = assert_grouping_invariance(saturated_events)
    assert wikimedia.payload["count"] == @uint32_max
    assert wikimedia.payload["total_absolute_byte_delta"] == @uint32_max

    assert Enum.all?(wikimedia.payload["language_buckets"], fn {_key, count} ->
             count == @uint32_max
           end)

    assert Enum.all?(wikimedia.payload["edit_types"], fn {_key, count} -> count == @uint32_max end)

    assert_saturated_window(wikimedia)

    bluesky =
      assert_grouping_invariance([
        saturated_bluesky_event(1, @maximum_window_count),
        saturated_bluesky_event(2, 1)
      ])

    assert Enum.all?(
             Map.take(
               bluesky.payload,
               ~w(total_actions original_posts replies reposts creates updates deletes)
             ),
             fn {_key, count} -> count == @uint32_max end
           )

    assert_saturated_window(bluesky)

    ripe =
      assert_grouping_invariance([
        saturated_ripe_event(1, @maximum_window_count),
        saturated_ripe_event(2, 2)
      ])

    assert Enum.all?(
             Map.take(
               ripe.payload,
               ~w(announced withdrawn ipv4 ipv6 collector_observations peer_observations)
             ),
             fn {_key, count} -> count == @uint32_max end
           )

    assert_saturated_window(ripe)

    solana =
      assert_grouping_invariance([
        saturated_solana_event(1, @maximum_window_count),
        saturated_solana_event(2, 1)
      ])

    assert solana.payload["slot_count"] == @uint32_max
    assert solana.payload["gap_count"] == @uint32_max
    assert_saturated_window(solana)
  end

  test "detects fresh sufficient-stat overflow instead of relying on input truncation" do
    almost_full =
      wikimedia_event(
        1,
        @uint32_max - 1,
        @uint32_max - 1,
        %{"current_1" => @uint32_max - 1},
        %{"edit" => @uint32_max - 1}
      )

    final_two =
      wikimedia_event(
        2,
        2,
        2,
        %{"current_1" => 2},
        %{"edit" => 2}
      )

    assert almost_full.payload["truncated"] == false
    assert final_two.payload["truncated"] == false
    assert {:ok, merged} = Merger.merge([almost_full, final_two])
    assert merged.payload["count"] == @uint32_max
    assert merged.payload["total_absolute_byte_delta"] == @uint32_max
    assert merged.payload["language_buckets"]["current_1"] == @uint32_max
    assert merged.payload["edit_types"]["edit"] == @uint32_max
    assert merged.payload["truncated"] == true
  end

  test "marks metadata-only window overflow without requiring activity-counter overflow" do
    almost_full =
      bluesky_pressure_event(1, @maximum_window_count, @uint32_max - 100)

    one_more = bluesky_pressure_event(2, 1, 1)

    assert almost_full.payload["truncated"] == false
    assert one_more.payload["truncated"] == false
    assert {:ok, merged} = Merger.merge([almost_full, one_more])
    assert merged.payload["window_count"] == @maximum_window_count
    assert merged.payload["total_actions"] == @uint32_max - 99
    assert merged.payload["creates"] == @uint32_max - 99
    assert merged.payload["truncated"] == true
    assert merged.payload["summary"] =~ "across at least #{@maximum_window_count} windows"
    assert merged.payload["summary"] =~ "at least #{@maximum_window_count * 4} seconds"
  end

  test "singleton events retain identity while drand remains unmergeable" do
    wikimedia = wikimedia_event(1, 1, 10, %{"current_1" => 1}, %{"edit" => 1})
    assert Merger.merge([wikimedia]) == {:ok, wikimedia}

    drand_events = [drand_event(41), drand_event(42)]
    assert Merger.merge(drand_events) == {:error, :unsupported_source}
  end

  test "rejects legacy Wikimedia events safely when pressure statistics are unavailable" do
    legacy = fn index ->
      SourceEvent.new!(%{
        kind: :wikimedia,
        source: :wikimedia,
        external_id: "legacy-wikimedia-#{index}",
        occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
        lane: 0.4,
        intensity: 0.6,
        payload: %{"summary" => "Legacy Wikimedia event #{index}"}
      })
    end

    assert Merger.merge([legacy.(1), legacy.(2)]) == {:error, :invalid_events}
  end

  test "rejects malformed Wikimedia pressure structs without raising" do
    valid = wikimedia_event(1, 8, 1_200, %{"current_1" => 8}, %{"edit" => 8})

    malformed =
      put_in(
        valid.payload["language_buckets"],
        Map.delete(valid.payload["language_buckets"], "current_5")
      )

    assert Merger.merge([valid, malformed]) == {:error, :invalid_events}
  end

  test "retains the strongest earthquake with bounded public context" do
    events =
      Enum.map(1..7, fn index ->
        earthquake_event(index, index / 2, "Public place #{index}")
      end)

    assert {:ok, merged} = Merger.merge(events)
    assert merged.kind == :earthquake
    assert merged.source == :usgs
    assert merged.payload["magnitude"] == 3.5
    assert merged.payload["place"] == "Public place 7"
    assert merged.payload["additional_count"] == 6
    assert length(merged.payload["places"]) == 5
    assert merged.payload["summary"] == "Magnitude 3.5 near Public place 7, plus 6 more"
  end

  test "weather overload keeps only the newest complete ambient state" do
    older = weather_event(1, ~U[2026-08-03 12:00:00.000000Z])
    newest = weather_event(2, ~U[2026-08-03 12:10:00.000000Z])

    assert {:ok, merged} = Merger.merge([newest, older])
    assert merged == newest
  end

  test "refuses to mix visual families" do
    assert {:error, :mixed_sources} =
             Merger.merge([
               wikimedia_event(1, 1, 10, %{"current_1" => 1}, %{"edit" => 1}),
               earthquake_event(1, 4.2, "South Atlantic Ocean")
             ])
  end

  defp assert_grouping_invariance(events) do
    assert {:ok, direct} = Merger.merge(events)

    for split <- 1..(length(events) - 1) do
      {left_events, right_events} = Enum.split(events, split)
      assert {:ok, left} = Merger.merge(left_events)
      assert {:ok, right} = Merger.merge(right_events)
      assert {:ok, regrouped} = Merger.merge([left, right])
      assert regrouped == direct
    end

    for _iteration <- 1..100 do
      assert {:ok, regrouped} = events |> Enum.shuffle() |> randomly_regroup()
      assert regrouped == direct
    end

    direct
  end

  defp randomly_regroup([event]), do: {:ok, event}

  defp randomly_regroup(events) do
    split = :rand.uniform(length(events) - 1)
    {left_events, right_events} = Enum.split(events, split)

    with {:ok, left} <- randomly_regroup(left_events),
         {:ok, right} <- randomly_regroup(right_events) do
      Merger.merge([left, right])
    end
  end

  defp assert_saturated_window(event) do
    assert event.payload["window_count"] == @maximum_window_count
    assert event.payload["window_span_seconds"] == @maximum_window_count * 4
    assert event.payload["truncated"] == true
  end

  defp wikimedia_event(
         index,
         count,
         bytes,
         language_buckets,
         edit_types,
         truncated \\ false,
         window_count \\ 1
       ) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: "wiki-bucket-#{index}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index * 4, :second),
      lane: rem(index * 31, 100) / 100,
      intensity: rem(index * 17, 100) / 100,
      payload: %{
        "summary" => "#{count} public edits",
        "window_count" => window_count,
        "window_span_seconds" => window_count * 4,
        "count" => count,
        "total_absolute_byte_delta" => bytes,
        "language_buckets" => complete_counts(@language_buckets, language_buckets),
        "edit_types" => complete_counts(@edit_types, edit_types),
        "dominant_edit_type" => dominant_key(edit_types, "edit"),
        "truncated" => truncated
      }
    })
  end

  defp bluesky_event(index, counts) do
    original_posts = Map.fetch!(counts, :original_posts)
    replies = Map.fetch!(counts, :replies)
    reposts = Map.fetch!(counts, :reposts)
    creates = Map.fetch!(counts, :creates)
    updates = Map.get(counts, :updates, 0)
    deletes = Map.get(counts, :deletes, 0)
    total_actions = creates + updates + deletes

    source_event(:public_activity, :bluesky, index, %{
      "summary" => "#{total_actions} public Bluesky actions",
      "window_count" => 1,
      "window_span_seconds" => 4,
      "total_actions" => total_actions,
      "original_posts" => original_posts,
      "replies" => replies,
      "reposts" => reposts,
      "creates" => creates,
      "updates" => updates,
      "deletes" => deletes,
      "truncated" => false
    })
  end

  defp saturated_bluesky_event(index, window_count) do
    source_event(:public_activity, :bluesky, index, %{
      "summary" => "Saturated Bluesky pressure",
      "window_count" => window_count,
      "window_span_seconds" => window_count * 4,
      "total_actions" => @uint32_max,
      "original_posts" => @uint32_max,
      "replies" => @uint32_max,
      "reposts" => @uint32_max,
      "creates" => @uint32_max,
      "updates" => @uint32_max,
      "deletes" => @uint32_max,
      "truncated" => true
    })
  end

  defp bluesky_pressure_event(index, window_count, total_actions) do
    source_event(:public_activity, :bluesky, index, %{
      "summary" => "Bounded Bluesky pressure",
      "window_count" => window_count,
      "window_span_seconds" => window_count * 4,
      "total_actions" => total_actions,
      "original_posts" => total_actions,
      "replies" => 0,
      "reposts" => 0,
      "creates" => total_actions,
      "updates" => 0,
      "deletes" => 0,
      "truncated" => false
    })
  end

  defp ripe_event(index, announced, withdrawn, ipv4, ipv6, collectors, peers) do
    source_event(:route_change, :ripe_ris, index, %{
      "summary" => "#{announced + withdrawn} RIPE route changes",
      "window_count" => 1,
      "window_span_seconds" => 4,
      "announced" => announced,
      "withdrawn" => withdrawn,
      "ipv4" => ipv4,
      "ipv6" => ipv6,
      "collector_observations" => collectors,
      "peer_observations" => peers,
      "truncated" => false
    })
  end

  defp saturated_ripe_event(index, window_count) do
    source_event(:route_change, :ripe_ris, index, %{
      "summary" => "Saturated RIPE pressure",
      "window_count" => window_count,
      "window_span_seconds" => window_count * 4,
      "announced" => @uint32_max,
      "withdrawn" => @uint32_max,
      "ipv4" => @uint32_max,
      "ipv6" => @uint32_max,
      "collector_observations" => @uint32_max,
      "peer_observations" => @uint32_max,
      "truncated" => true
    })
  end

  defp solana_event(index, slot_count, first_slot, last_slot, gap_count) do
    source_event(:slot, :solana, index, %{
      "summary" => "#{slot_count} Solana slots",
      "window_count" => 1,
      "window_span_seconds" => 4,
      "slot_count" => slot_count,
      "first_slot" => first_slot,
      "last_slot" => last_slot,
      "gap_count" => gap_count,
      "truncated" => false
    })
  end

  defp saturated_solana_event(index, window_count) do
    source_event(:slot, :solana, index, %{
      "summary" => "Saturated Solana pressure",
      "window_count" => window_count,
      "window_span_seconds" => window_count * 4,
      "slot_count" => @uint32_max,
      "first_slot" => index * 10,
      "last_slot" => 9_007_199_254_740_000 + index,
      "gap_count" => @uint32_max,
      "truncated" => true
    })
  end

  defp source_event(kind, source, index, payload) do
    SourceEvent.new!(%{
      kind: kind,
      source: source,
      external_id: "#{source}-window-#{index}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index * 4, :second),
      lane: rem(index * 23, 100) / 100,
      intensity: rem(index * 29, 100) / 100,
      payload: payload
    })
  end

  defp drand_event(round) do
    SourceEvent.new!(%{
      kind: :randomness,
      source: :drand,
      external_id: "drand-round:#{round}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], round * 3, :second),
      lane: 0.2,
      intensity: 0.6,
      payload: %{"summary" => "drand Quicknet round #{round}", "round" => round},
      render_identity: String.duplicate(Integer.to_string(rem(round, 10)), 64)
    })
  end

  defp earthquake_event(index, magnitude, place) do
    SourceEvent.new!(%{
      kind: :earthquake,
      source: :usgs,
      external_id: "quake-#{index}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
      lane: index / 10,
      intensity: min(magnitude / 10, 1.0),
      payload: %{
        "summary" => "Magnitude #{magnitude} near #{place}",
        "magnitude" => magnitude,
        "place" => place,
        "coordinates" => [-24.1 + index, -58.2]
      }
    })
  end

  defp weather_event(index, occurred_at) do
    SourceEvent.new!(%{
      kind: :weather,
      source: :open_meteo,
      external_id: "weather-#{index}",
      occurred_at: occurred_at,
      lane: 0.3,
      intensity: 0.5,
      payload: %{
        "summary" => "Ambient weather sample #{index}",
        "temperature_range" => [12.0, 28.0],
        "precipitation_coverage" => 0.25,
        "mean_wind" => 14.2,
        "day_night_ratio" => 0.5,
        "cities" => ["Vancouver", "Sydney"]
      }
    })
  end

  defp complete_counts(keys, counts), do: Map.new(keys, &{&1, Map.get(counts, &1, 0)})

  defp dominant_key(counts, default) when map_size(counts) == 0, do: default

  defp dominant_key(counts, _default) do
    counts
    |> Enum.max_by(fn {key, count} -> {count, key} end)
    |> elem(0)
  end
end
