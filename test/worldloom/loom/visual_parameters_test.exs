defmodule Worldloom.Loom.VisualParametersTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.VisualParameters

  @drand_identity String.duplicate("a", 64)

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

  test "version two sources have stable source-aware visual parameters" do
    expected_parameters = [
      %{
        render_version: 2,
        render_seed: 1_486_784_049,
        visual: %{"spread" => 0.512766, "bend" => 0.945871, "pulse" => 0.719006}
      },
      %{
        render_version: 2,
        render_seed: 343_691_020,
        visual: %{"spread" => 0.180385, "bend" => 0.458346, "pulse" => 0.872649}
      },
      %{
        render_version: 2,
        render_seed: 1_533_575_821,
        visual: %{"spread" => 0.17227, "bend" => -0.943165, "pulse" => 0.629568}
      },
      %{
        render_version: 2,
        render_seed: 754_817_822,
        visual: %{"spread" => 0.423287, "bend" => -0.39182, "pulse" => 0.706074}
      }
    ]

    actual_parameters = Enum.map(version_two_source_events(), &VisualParameters.for(&1, nil))

    assert actual_parameters == expected_parameters

    Enum.each(actual_parameters, fn parameters ->
      assert parameters.render_seed in 0..2_147_483_646

      assert_finite_between(parameters.visual["spread"], 0.0, 1.0)
      assert_finite_between(parameters.visual["bend"], -1.0, 1.0)
      assert_finite_between(parameters.visual["pulse"], 0.0, 1.0)
    end)
  end

  test "drand beacon output is the complete visual identity" do
    first = drand_event("drand-round:42", 42, ~U[2026-08-03 12:01:03.000000Z], @drand_identity)

    same_beacon_different_metadata =
      drand_event("drand-round:9001", 9_001, ~U[2027-01-02 03:04:05.000000Z], @drand_identity)

    different_beacon =
      drand_event(
        "drand-round:42",
        42,
        ~U[2026-08-03 12:01:03.000000Z],
        String.duplicate("b", 64)
      )

    assert VisualParameters.for(first, nil) ==
             VisualParameters.for(same_beacon_different_metadata, nil)

    refute VisualParameters.for(first, nil).render_seed ==
             VisualParameters.for(different_beacon, nil).render_seed
  end

  test "rejects a malformed drand identity without exposing it" do
    invalid_identity = "not-a-validated-beacon-output"

    event = %SourceEvent{
      kind: :randomness,
      source: :drand,
      external_id: "drand-round:42",
      occurred_at: ~U[2026-08-03 12:01:03.000000Z],
      lane: 0.5,
      intensity: 0.7,
      payload: %{"summary" => "drand Quicknet round 42", "round" => 42},
      render_identity: invalid_identity
    }

    error = assert_raise ArgumentError, fn -> VisualParameters.for(event, nil) end

    assert error.message =~ "validated render identity"
    refute error.message =~ invalid_identity
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

  defp version_two_source_events do
    [
      SourceEvent.new!(%{
        kind: :public_activity,
        source: :bluesky,
        external_id: "bluesky-window:1785758461:4",
        occurred_at: ~U[2026-08-03 12:01:01.000000Z],
        lane: 0.2,
        intensity: 0.5,
        payload: %{
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
      }),
      SourceEvent.new!(%{
        kind: :route_change,
        source: :ripe_ris,
        external_id: "ripe-ris-window:1785758462:4",
        occurred_at: ~U[2026-08-03 12:01:02.000000Z],
        lane: 0.3,
        intensity: 0.6,
        payload: %{
          "summary" => "Public routes shifted through the weave",
          "window_count" => 1,
          "window_span_seconds" => 4,
          "announced" => 31,
          "withdrawn" => 4,
          "ipv4" => 28,
          "ipv6" => 7,
          "collector_count" => 2,
          "peer_count" => 18,
          "truncated" => false
        }
      }),
      SourceEvent.new!(%{
        kind: :slot,
        source: :solana,
        external_id: "solana-window:1785758463:4",
        occurred_at: ~U[2026-08-03 12:01:03.000000Z],
        lane: 0.4,
        intensity: 0.7,
        payload: %{
          "summary" => "Public computation advanced through the weave",
          "window_count" => 1,
          "window_span_seconds" => 4,
          "slot_count" => 4,
          "first_slot" => 101,
          "last_slot" => 105,
          "gap_count" => 1
        }
      }),
      drand_event("drand-round:42", 42, ~U[2026-08-03 12:01:03.000000Z], @drand_identity)
    ]
  end

  defp drand_event(external_id, round, occurred_at, render_identity) do
    SourceEvent.new!(%{
      kind: :randomness,
      source: :drand,
      external_id: external_id,
      occurred_at: occurred_at,
      lane: 0.5,
      intensity: 0.8,
      payload: %{"summary" => "drand Quicknet round #{round}", "round" => round},
      render_identity: render_identity
    })
  end

  defp assert_finite_between(number, minimum, maximum) do
    assert is_float(number)
    assert number == number
    assert number >= minimum
    assert number <= maximum
  end
end
