defmodule Worldloom.Loom.SourceEventTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.SourceEvent

  @pairs [
    {:wikimedia, :wikimedia},
    {:earthquake, :usgs},
    {:weather, :open_meteo},
    {:tug, :visitor},
    {:knot, :visitor},
    {:illuminate, :visitor}
  ]

  test "accepts every approved kind and source pairing" do
    Enum.each(@pairs, fn {kind, source} ->
      assert {:ok, %SourceEvent{kind: ^kind, source: ^source}} =
               SourceEvent.new(valid_attributes(kind, source))
    end)
  end

  test "rejects untrusted strings and invalid field types without creating atoms" do
    assert {:error, {:kind, :invalid}} =
             SourceEvent.new(valid_attributes(:wikimedia, :wikimedia, %{kind: "wikimedia"}))

    assert {:error, {:lane, :invalid}} =
             SourceEvent.new(valid_attributes(:wikimedia, :wikimedia, %{lane: 1}))

    assert {:error, {:occurred_at, :invalid}} =
             SourceEvent.new(
               valid_attributes(:wikimedia, :wikimedia, %{occurred_at: "2026-08-03T12:00:00Z"})
             )
  end

  test "normalizes non-UTC DateTimes to UTC" do
    denver_noon = %DateTime{
      year: 2026,
      month: 8,
      day: 3,
      hour: 12,
      minute: 0,
      second: 0,
      microsecond: {0, 0},
      time_zone: "America/Denver",
      zone_abbr: "MDT",
      utc_offset: -21_600,
      std_offset: 0,
      calendar: Calendar.ISO
    }

    assert {:ok, event} =
             SourceEvent.new(
               valid_attributes(:wikimedia, :wikimedia, %{occurred_at: denver_noon})
             )

    assert event.occurred_at == ~U[2026-08-03 18:00:00.000000Z]
    assert event.occurred_at.time_zone == "Etc/UTC"
  end

  test "normalizes upstream millisecond timestamps to database microsecond precision" do
    assert {:ok, event} =
             SourceEvent.new(
               valid_attributes(:earthquake, :usgs, %{
                 occurred_at: ~U[2026-08-03 08:23:20.450Z]
               })
             )

    assert event.occurred_at == ~U[2026-08-03 08:23:20.450000Z]
    assert event.occurred_at.microsecond == {450_000, 6}
  end

  test "enforces lane and intensity bounds" do
    assert {:error, {:lane, :out_of_bounds}} =
             SourceEvent.new(valid_attributes(:wikimedia, :wikimedia, %{lane: -0.001}))

    assert {:error, {:intensity, :out_of_bounds}} =
             SourceEvent.new(valid_attributes(:wikimedia, :wikimedia, %{intensity: 1.001}))
  end

  test "enforces external identity rules" do
    assert {:error, {:external_id, :required}} =
             SourceEvent.new(valid_attributes(:earthquake, :usgs, %{external_id: nil}))

    assert {:error, {:external_id, :forbidden}} =
             SourceEvent.new(valid_attributes(:tug, :visitor, %{external_id: "visitor-1"}))

    assert {:ok, %SourceEvent{external_id: nil}} =
             SourceEvent.new(valid_attributes(:tug, :visitor))
  end

  test "allows only source-specific public payload fields" do
    assert {:error, {:payload, :invalid_keys}} =
             SourceEvent.new(
               valid_attributes(:wikimedia, :wikimedia, %{
                 payload: %{"summary" => "A change", "username" => "private"}
               })
             )

    assert {:error, {:payload, :invalid_keys}} =
             SourceEvent.new(
               valid_attributes(:wikimedia, :wikimedia, %{
                 payload: %{summary: "Atom keys are not accepted"}
               })
             )

    assert {:ok, event} =
             SourceEvent.new(
               valid_attributes(:earthquake, :usgs, %{
                 payload: %{
                   "summary" => "Magnitude 5.2 in the South Atlantic",
                   "magnitude" => 5.2,
                   "place" => "South Atlantic Ocean",
                   "coordinates" => [-24.1, -58.2]
                 }
               })
             )

    assert event.payload |> Map.keys() |> Enum.sort() ==
             ["coordinates", "magnitude", "place", "summary"]
  end

  test "requires concise textual summaries" do
    assert {:error, {:payload, :summary_required}} =
             SourceEvent.new(valid_attributes(:wikimedia, :wikimedia, %{payload: %{}}))

    assert {:error, {:payload, :summary_too_long}} =
             SourceEvent.new(
               valid_attributes(:wikimedia, :wikimedia, %{
                 payload: %{"summary" => String.duplicate("x", 161)}
               })
             )
  end

  test "new! raises for invalid trusted construction" do
    assert_raise ArgumentError, ~r/invalid source event/, fn ->
      SourceEvent.new!(valid_attributes(:wikimedia, :visitor))
    end
  end

  defp valid_attributes(kind, source, overrides \\ %{}) do
    external_id = if source == :visitor, do: nil, else: "external-41"

    Map.merge(
      %{
        kind: kind,
        source: source,
        external_id: external_id,
        occurred_at: ~U[2026-08-03 12:00:00.000000Z],
        lane: 0.4,
        intensity: 0.6,
        payload: %{"summary" => "A public signal entered the weave"}
      },
      overrides
    )
  end
end
