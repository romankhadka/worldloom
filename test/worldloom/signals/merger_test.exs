defmodule Worldloom.Signals.MergerTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Signals.Merger

  test "merges Wikimedia counts, bytes, languages, intensity, summaries, and identities" do
    events = [
      wikimedia_event(1, 3, 120, %{"en" => 2, "fr" => 1}, "edit", 0.35),
      wikimedia_event(2, 5, 80, %{"en" => 1, "de" => 4}, "new", 0.55)
    ]

    assert {:ok, merged} = Merger.merge(events)
    assert merged.kind == :wikimedia
    assert merged.source == :wikimedia
    assert merged.external_id =~ "merged:"
    refute merged.external_id in Enum.map(events, & &1.external_id)
    assert merged.intensity == 0.9
    assert merged.payload["count"] == 8
    assert merged.payload["total_absolute_byte_delta"] == 200
    assert merged.payload["languages"] == %{"de" => 4, "en" => 3, "fr" => 1}
    assert merged.payload["dominant_edit_type"] == "new"
    assert merged.payload["summary"] == "8 edits moved through 3 languages"

    assert {:ok, reordered} = Merger.merge(Enum.reverse(events))
    assert reordered.external_id == merged.external_id

    assert {:ok, first_group} = Merger.merge(events)
    third = wikimedia_event(3, 2, 50, %{"es" => 2}, "edit", 0.1)
    assert {:ok, regrouped} = Merger.merge([first_group, third])
    assert {:ok, all_at_once} = Merger.merge(events ++ [third])
    assert regrouped.external_id == all_at_once.external_id
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
               wikimedia_event(1, 1, 10, %{"en" => 1}, "edit", 0.2),
               earthquake_event(1, 4.2, "South Atlantic Ocean")
             ])
  end

  defp wikimedia_event(index, count, bytes, languages, edit_type, intensity) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: "wiki-bucket-#{index}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
      lane: 0.4,
      intensity: intensity,
      payload: %{
        "summary" => "#{count} public edits",
        "count" => count,
        "total_absolute_byte_delta" => bytes,
        "languages" => languages,
        "dominant_edit_type" => edit_type
      }
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
end
