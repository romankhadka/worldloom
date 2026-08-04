defmodule Worldloom.Signals.NormalizerTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Signals.Normalizer

  @fixtures "test/support/fixtures/feeds"
  @forbidden ~w(user user_text ip title comment revision server_url)

  test "normalizes a privacy-preserving Wikimedia bucket" do
    frames = read_fixture("wikimedia_frames.json")

    bucket = %{
      second: ~U[2026-08-03 12:00:00Z],
      cursor: "opaque-stream-cursor",
      count: length(frames),
      total_absolute_byte_delta: 45,
      languages: %{"en" => 2, "de" => 1},
      edit_types: %{"edit" => 2, "new" => 1}
    }

    assert {:ok, %SourceEvent{} = event} = Normalizer.wikimedia_bucket(bucket)
    assert event.kind == :wikimedia
    assert event.source == :wikimedia
    assert event.external_id == "wikimedia-second:1785758400"
    assert event.occurred_at == ~U[2026-08-03 12:00:00.000000Z]
    assert event.lane >= 0.0 and event.lane <= 1.0
    assert event.intensity >= 0.0 and event.intensity <= 1.0

    assert event.payload == %{
             "summary" => "3 edits moved through 2 languages",
             "count" => 3,
             "total_absolute_byte_delta" => 45,
             "languages" => %{"de" => 1, "en" => 2},
             "dominant_edit_type" => "edit"
           }

    refute inspect(event) =~ "opaque-stream-cursor"
    assert private_noise_absent?(event)
  end

  test "normalizes public USGS features and clamps impossible magnitudes" do
    geojson = read_fixture("usgs.json")

    assert {:ok, events} = Normalizer.earthquakes(geojson)
    assert length(events) == 3
    assert Enum.map(events, & &1.external_id) == ~w(us-test-alpha us-test-beta us-test-gamma)
    assert Enum.map(events, & &1.payload["magnitude"]) == [5.2, 0.0, 10.0]
    assert Enum.map(events, & &1.intensity) == [0.52, 0.0, 1.0]
    assert Enum.all?(events, &(&1.lane >= 0.0 and &1.lane <= 1.0))
    assert Enum.all?(events, &(String.length(&1.payload["summary"]) <= 160))
    assert Enum.all?(events, &private_noise_absent?/1)
  end

  test "aggregates weather only across the reviewed anchor labels" do
    responses = read_fixture("open_meteo.json")
    anchors = ["Vancouver", "Lagos", "Sydney"]

    assert {:ok, event} = Normalizer.weather(responses, anchors)
    assert event.kind == :weather
    assert event.source == :open_meteo
    assert event.external_id == "weather:2026-08-03T12:00:00Z"
    assert event.payload["temperature_range"] == [14.0, 28.0]
    assert event.payload["precipitation_coverage"] == 0.333333
    assert event.payload["mean_wind"] == 16.666667
    assert event.payload["day_night_ratio"] == 0.666667
    assert event.payload["cities"] == anchors
    assert event.lane >= 0.0 and event.lane <= 1.0
    assert event.intensity >= 0.0 and event.intensity <= 1.0
    assert private_noise_absent?(event)
  end

  test "rejects malformed upstream collections and drops malformed USGS features" do
    assert {:error, :invalid_bucket} = Normalizer.wikimedia_bucket(%{count: 1})
    assert {:error, :invalid_geojson} = Normalizer.earthquakes(%{"features" => "wrong"})
    assert {:ok, []} = Normalizer.earthquakes(%{"features" => [%{"id" => nil}]})
    assert {:error, :invalid_weather} = Normalizer.weather([%{}], ["Vancouver"])
    assert {:error, :invalid_weather} = Normalizer.weather([], [])
  end

  test "fixture directory itself contains no forbidden raw Wikimedia fields" do
    fixture = File.read!(Path.join(@fixtures, "wikimedia_frames.json"))

    Enum.each(@forbidden, fn forbidden ->
      refute String.contains?(String.downcase(fixture), forbidden)
    end)
  end

  defp read_fixture(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp private_noise_absent?(event) do
    event
    |> Map.from_struct()
    |> nested_keys()
    |> Enum.map(&(&1 |> to_string() |> String.downcase()))
    |> Enum.all?(&(&1 not in @forbidden))
  end

  defp nested_keys(value) when is_struct(value), do: []

  defp nested_keys(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested_value} -> [key | nested_keys(nested_value)] end)
  end

  defp nested_keys(value) when is_list(value), do: Enum.flat_map(value, &nested_keys/1)
  defp nested_keys(_value), do: []
end
