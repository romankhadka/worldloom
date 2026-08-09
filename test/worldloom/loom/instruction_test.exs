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

  @approved_pairs [
    {"wikimedia", "wikimedia"},
    {"earthquake", "usgs"},
    {"weather", "open_meteo"},
    {"tug", "visitor"},
    {"knot", "visitor"},
    {"illuminate", "visitor"},
    {"public_activity", "bluesky"},
    {"route_change", "ripe_ris"},
    {"slot", "solana"},
    {"randomness", "drand"}
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

  test "keeps metrics out of the version one contract even when its payload has metric-like fields" do
    event = %Event{
      id: 43,
      kind: "wikimedia",
      source: "wikimedia",
      occurred_at: ~U[2026-08-03 12:00:00.000000Z],
      render_version: 1,
      render_seed: 173_881_294,
      lane: 0.61,
      intensity: 0.78,
      payload: %{
        "summary" => "A public signal entered the weave",
        "visual" => %{"spread" => 0.42, "bend" => -0.18, "pulse" => 0.73},
        "window_count" => 1,
        "window_span_seconds" => 4,
        "total_actions" => 12
      }
    }

    instruction = Instruction.from_event(event)

    refute Map.has_key?(instruction, "metrics")
  end

  test "adds exact source metrics to the version two contract" do
    event = v2_stored_event(201, "public_activity", "bluesky", bluesky_payload())

    assert Instruction.from_event(event)["metrics"] == %{
             "window_count" => 1,
             "window_span_seconds" => 4,
             "total_actions" => 12,
             "original_posts" => 4,
             "replies" => 2,
             "reposts" => 1,
             "creates" => 8,
             "updates" => 3,
             "deletes" => 1,
             "truncated" => false
           }
  end

  test "rejects a malformed version two stored event instead of emitting a partial contract" do
    malformed_payload = Map.put(bluesky_payload(), "total_actions", 1.0)
    event = v2_stored_event(201, "public_activity", "bluesky", malformed_payload)

    assert_raise ArgumentError, ~r/unsupported stored event/, fn ->
      Instruction.from_event(event)
    end
  end

  test "preserves unknown positive render versions for the client fallback" do
    event = stored_event(1, :wikimedia, :wikimedia, "revision-1", nil, 9)

    assert %{"render_version" => 9, "kind" => "wikimedia"} =
             Instruction.from_event(event)
  end

  test "recognizes every approved stored kind and source pairing" do
    Enum.each(Enum.with_index(@approved_pairs, 1), fn {{kind, source}, sequence} ->
      event = %Event{
        id: sequence,
        kind: kind,
        source: source,
        external_id: if(source == "visitor", do: nil, else: "#{source}-#{sequence}"),
        occurred_at: ~U[2026-08-03 12:00:00.000000Z],
        render_version: if(source in ~w(bluesky ripe_ris solana drand), do: 2, else: 1),
        render_seed: sequence,
        lane: 0.4,
        intensity: 0.6,
        payload: approved_pair_payload(source)
      }

      assert %{"kind" => ^kind, "source" => ^source} = Instruction.from_event(event)
    end)
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

  test "all four v2 sources reproduce the hand-reviewed golden fixture" do
    expected =
      "test/support/fixtures/render_contract_v2.json"
      |> File.read!()
      |> Jason.decode!()

    actual = [
      v2_stored_event(201, "public_activity", "bluesky", bluesky_payload()),
      v2_stored_event(202, "route_change", "ripe_ris", ripe_ris_payload()),
      v2_stored_event(203, "slot", "solana", solana_payload()),
      v2_stored_event(204, "randomness", "drand", drand_payload())
    ]

    assert Enum.map(actual, &Instruction.from_event/1) == expected
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

  defp v2_stored_event(sequence, kind, source, payload) do
    offset = sequence - 201
    {lane, intensity, visual} = v2_visuals(offset)

    %Event{
      id: sequence,
      kind: kind,
      source: source,
      external_id: "#{source}-#{sequence}",
      occurred_at: DateTime.add(~U[2026-08-03 12:01:00.000000Z], offset, :second),
      render_version: 2,
      render_seed: 201_000 + offset,
      lane: lane,
      intensity: intensity,
      payload: Map.put(payload, "visual", visual)
    }
  end

  defp v2_visuals(0), do: {0.2, 0.5, %{"spread" => 0.3, "bend" => -0.15, "pulse" => 0.6}}
  defp v2_visuals(1), do: {0.3, 0.6, %{"spread" => 0.4, "bend" => -0.05, "pulse" => 0.7}}
  defp v2_visuals(2), do: {0.4, 0.7, %{"spread" => 0.5, "bend" => 0.05, "pulse" => 0.8}}
  defp v2_visuals(3), do: {0.5, 0.8, %{"spread" => 0.6, "bend" => 0.15, "pulse" => 0.9}}

  defp approved_pair_payload("bluesky"), do: Map.put(bluesky_payload(), "visual", visual())
  defp approved_pair_payload("ripe_ris"), do: Map.put(ripe_ris_payload(), "visual", visual())
  defp approved_pair_payload("solana"), do: Map.put(solana_payload(), "visual", visual())
  defp approved_pair_payload("drand"), do: Map.put(drand_payload(), "visual", visual())

  defp approved_pair_payload(_source) do
    %{"summary" => "A public signal entered the weave", "visual" => visual()}
  end

  defp visual, do: %{"spread" => 0.2, "bend" => 0.0, "pulse" => 0.4}

  defp bluesky_payload do
    %{
      "summary" => "Public conversation moved through the weave",
      "window_count" => 1,
      "window_span_seconds" => 4,
      "total_actions" => 12,
      "original_posts" => 4,
      "replies" => 2,
      "reposts" => 1,
      "creates" => 8,
      "updates" => 3,
      "deletes" => 1,
      "truncated" => false
    }
  end

  defp ripe_ris_payload do
    %{
      "summary" => "Public routes shifted through the weave",
      "window_count" => 2,
      "window_span_seconds" => 8,
      "announced" => 31,
      "withdrawn" => 4,
      "ipv4" => 28,
      "ipv6" => 7,
      "collector_count" => 2,
      "peer_count" => 18,
      "truncated" => false
    }
  end

  defp solana_payload do
    %{
      "summary" => "Public computation advanced through the weave",
      "window_count" => 1,
      "window_span_seconds" => 4,
      "slot_count" => 4,
      "first_slot" => 101,
      "last_slot" => 105,
      "gap_count" => 1,
      "truncated" => false
    }
  end

  defp drand_payload do
    %{"summary" => "drand Quicknet round 42", "round" => 42}
  end
end
