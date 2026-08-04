defmodule Worldloom.Loom.InstructionTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.Event
  alias Worldloom.Loom.Instruction
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.VisualParameters

  @golden_cases [
    {101, :wikimedia, :wikimedia, "wiki-bucket-120000", nil, ~U[2026-08-03 12:00:00.000000Z],
     0.18, 0.42, "18 edits moved through 7 languages"},
    {102, :earthquake, :usgs, "us7000alpha", nil, ~U[2026-08-03 12:00:01.000000Z], 0.61, 0.78,
     "Magnitude 5.2 near South Sandwich Islands"},
    {103, :weather, :open_meteo, "weather-120000", nil, ~U[2026-08-03 12:00:02.000000Z], 0.35,
     0.55, "A mild, windy pattern crosses twelve cities"},
    {104, :tug, :visitor, nil, "visitor-nonce-tug", ~U[2026-08-03 12:00:03.000000Z], 0.25, 0.4,
     "A visitor tugged the living edge"},
    {105, :knot, :visitor, nil, "visitor-nonce-knot", ~U[2026-08-03 12:00:04.000000Z], 0.5, 0.6,
     "A visitor tied a knot in the weave"},
    {106, :illuminate, :visitor, nil, "visitor-nonce-illuminate", ~U[2026-08-03 12:00:05.000000Z],
     0.75, 0.8, "A visitor illuminated a thread"}
  ]

  test "emits the exact string-keyed client contract and strips private payload fields" do
    event = %Event{
      id: 42,
      kind: "earthquake",
      source: "usgs",
      occurred_at: ~U[2026-08-03 12:00:00.000000Z],
      render_version: 1,
      render_seed: 173_881_294,
      lane: 0.61,
      intensity: 0.78,
      payload: %{
        "summary" => "Magnitude 5.2 near South Sandwich Islands",
        "visual" => %{"spread" => 0.42, "bend" => -0.18, "pulse" => 0.73},
        "coordinates" => [-24.1, -58.2],
        "internal" => "must not leave the server"
      }
    }

    assert Instruction.from_event(event) == %{
             "sequence" => 42,
             "kind" => "earthquake",
             "source" => "usgs",
             "occurred_at" => "2026-08-03T12:00:00.000000Z",
             "render_version" => 1,
             "seed" => 173_881_294,
             "lane" => 0.61,
             "intensity" => 0.78,
             "visual" => %{"spread" => 0.42, "bend" => -0.18, "pulse" => 0.73},
             "summary" => "Magnitude 5.2 near South Sandwich Islands"
           }
  end

  test "preserves unknown positive render versions for the client fallback" do
    event = stored_event(1, :wikimedia, :wikimedia, "revision-1", nil, 9)

    assert %{"render_version" => 9, "kind" => "wikimedia"} =
             Instruction.from_event(event)
  end

  test "rejects unknown or mismatched stored kind and source values" do
    unknown = %{stored_event(1, :wikimedia, :wikimedia, "revision-1", nil) | kind: "future"}
    mismatch = %{stored_event(1, :wikimedia, :wikimedia, "revision-1", nil) | source: "usgs"}

    assert_raise ArgumentError, ~r/unsupported stored event/, fn ->
      Instruction.from_event(unknown)
    end

    assert_raise ArgumentError, ~r/unsupported stored event/, fn ->
      Instruction.from_event(mismatch)
    end
  end

  test "all six v1 kinds reproduce the hand-reviewed golden fixture" do
    expected =
      "test/support/fixtures/render_contract_v1.json"
      |> File.read!()
      |> Jason.decode!()

    actual =
      Enum.map(@golden_cases, fn {sequence, kind, source, external_id, nonce, occurred_at, lane,
                                  intensity, summary} ->
        source_event =
          SourceEvent.new!(%{
            kind: kind,
            source: source,
            external_id: external_id,
            occurred_at: occurred_at,
            lane: lane,
            intensity: intensity,
            payload: %{"summary" => summary}
          })

        parameters = VisualParameters.for(source_event, nonce)

        %Event{
          id: sequence,
          kind: Atom.to_string(kind),
          source: Atom.to_string(source),
          external_id: external_id,
          occurred_at: occurred_at,
          render_version: parameters.render_version,
          render_seed: parameters.render_seed,
          lane: lane,
          intensity: intensity,
          payload: %{"summary" => summary, "visual" => parameters.visual}
        }
        |> Instruction.from_event()
      end)

    assert actual == expected
  end

  defp stored_event(sequence, kind, source, external_id, nonce, render_version \\ 1) do
    source_event =
      SourceEvent.new!(%{
        kind: kind,
        source: source,
        external_id: external_id,
        occurred_at: ~U[2026-08-03 12:00:00.000000Z],
        lane: 0.4,
        intensity: 0.6,
        payload: %{"summary" => "A public signal entered the weave"}
      })

    parameters = VisualParameters.for(source_event, nonce)

    %Event{
      id: sequence,
      kind: Atom.to_string(kind),
      source: Atom.to_string(source),
      external_id: external_id,
      occurred_at: source_event.occurred_at,
      render_version: render_version,
      render_seed: parameters.render_seed,
      lane: source_event.lane,
      intensity: source_event.intensity,
      payload: %{"summary" => source_event.payload["summary"], "visual" => parameters.visual}
    }
  end
end
