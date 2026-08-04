defmodule Worldloom.Loom.VisualParametersTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.VisualParameters

  test "identical input has stable seed and visual output" do
    event = source_event("wiki-bucket-120000", ~U[2026-08-03 12:00:00.000000Z])

    expected = %{
      render_version: 1,
      render_seed: 1_470_300_345,
      visual: %{"spread" => 0.75469, "bend" => 0.638649, "pulse" => 0.9962}
    }

    assert VisualParameters.for(event, nil) == expected
    assert VisualParameters.for(event, nil) == expected
  end

  test "distinct external ids produce distinct visuals" do
    first = source_event("revision-1", ~U[2026-08-03 12:00:00.000000Z])
    second = source_event("revision-2", ~U[2026-08-03 12:00:00.000000Z])

    refute VisualParameters.for(first, nil) == VisualParameters.for(second, nil)
  end

  test "visitor gestures use the transient request nonce" do
    event = %SourceEvent{
      kind: :tug,
      source: :visitor,
      external_id: nil,
      occurred_at: ~U[2026-08-03 12:00:03.000000Z],
      lane: 0.25,
      intensity: 0.4,
      payload: %{"summary" => "A visitor tugged the living edge"}
    }

    assert %{render_seed: 1_219_534_469} =
             VisualParameters.for(event, "visitor-nonce-tug")

    assert_raise ArgumentError, ~r/request nonce/, fn -> VisualParameters.for(event, nil) end
  end

  test "one thousand inputs stay deterministic and JavaScript-safe" do
    Enum.each(1..1_000, fn index ->
      event =
        source_event(
          "revision-#{index}",
          DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second)
        )

      first = VisualParameters.for(event, nil)
      second = VisualParameters.for(event, nil)

      assert first == second
      assert first.render_seed in 0..2_147_483_646
      assert first.visual["spread"] >= 0.0 and first.visual["spread"] <= 1.0
      assert first.visual["bend"] >= -1.0 and first.visual["bend"] <= 1.0
      assert first.visual["pulse"] >= 0.0 and first.visual["pulse"] <= 1.0
    end)
  end

  defp source_event(external_id, occurred_at) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: external_id,
      occurred_at: occurred_at,
      lane: 0.4,
      intensity: 0.6,
      payload: %{"summary" => "A public signal entered the weave"}
    })
  end
end
