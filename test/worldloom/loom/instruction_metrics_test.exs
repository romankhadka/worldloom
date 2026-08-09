defmodule Worldloom.Loom.InstructionMetricsTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.InstructionMetrics

  @json_safe_max 9_007_199_254_740_991
  @uint32_max 4_294_967_295

  @payloads %{
    "bluesky" => %{
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
    },
    "ripe_ris" => %{
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
    },
    "solana" => %{
      "summary" => "Public computation advanced through the weave",
      "window_count" => 1,
      "window_span_seconds" => 4,
      "slot_count" => 4,
      "first_slot" => 101,
      "last_slot" => 105,
      "gap_count" => 1,
      "truncated" => false
    },
    "drand" => %{
      "summary" => "drand Quicknet round 42",
      "round" => 42
    }
  }

  @expected_metrics %{
    "bluesky" => %{
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
    },
    "ripe_ris" => %{
      "window_count" => 2,
      "window_span_seconds" => 8,
      "announced" => 31,
      "withdrawn" => 4,
      "ipv4" => 28,
      "ipv6" => 7,
      "collector_count" => 2,
      "peer_count" => 18,
      "truncated" => false
    },
    "solana" => %{
      "window_count" => 1,
      "window_span_seconds" => 4,
      "slot_count" => 4,
      "first_slot" => 101,
      "last_slot" => 105,
      "gap_count" => 1,
      "truncated" => false
    },
    "drand" => %{"round" => 42}
  }

  test "projects the exact public metrics for every version two source" do
    Enum.each(@expected_metrics, fn {source, expected_metrics} ->
      assert InstructionMetrics.from_payload(source, Map.fetch!(@payloads, source)) ==
               expected_metrics
    end)
  end

  test "rebuilds metrics from the allow list and discards every other payload field" do
    Enum.each(@payloads, fn {source, payload} ->
      payload =
        Map.merge(payload, %{
          "visual" => %{"spread" => 0.4, "bend" => -0.2, "pulse" => 0.8},
          "private_identifier" => "must not leave the server",
          "unknown_counter" => 99
        })

      metrics = InstructionMetrics.from_payload(source, payload)

      assert metrics == Map.fetch!(@expected_metrics, source)
      refute Map.has_key?(metrics, "summary")
      refute Map.has_key?(metrics, "visual")
      refute Map.has_key?(metrics, "private_identifier")
      refute Map.has_key?(metrics, "unknown_counter")
    end)
  end

  test "accepts unsigned thirty-two-bit boundaries while preserving source semantics" do
    maximum_window_count = div(@uint32_max, 4)

    boundary_payloads = [
      {"bluesky",
       @payloads["bluesky"]
       |> Map.merge(%{
         "window_count" => maximum_window_count,
         "window_span_seconds" => maximum_window_count * 4,
         "total_actions" => @uint32_max,
         "original_posts" => @uint32_max,
         "replies" => @uint32_max,
         "reposts" => @uint32_max,
         "creates" => @uint32_max,
         "updates" => @uint32_max,
         "deletes" => @uint32_max,
         "truncated" => true
       })},
      {"ripe_ris",
       @payloads["ripe_ris"]
       |> Map.merge(%{
         "window_count" => maximum_window_count,
         "window_span_seconds" => maximum_window_count * 4,
         "announced" => @uint32_max,
         "withdrawn" => @uint32_max,
         "ipv4" => @uint32_max,
         "ipv6" => @uint32_max,
         "collector_count" => @uint32_max,
         "peer_count" => @uint32_max,
         "truncated" => true
       })},
      {"solana",
       @payloads["solana"]
       |> Map.merge(%{
         "slot_count" => @uint32_max,
         "first_slot" => 0,
         "last_slot" => @json_safe_max,
         "gap_count" => @uint32_max,
         "truncated" => true
       })},
      {"drand", Map.put(@payloads["drand"], "round", @uint32_max)}
    ]

    Enum.each(boundary_payloads, fn {source, payload} ->
      assert is_map(InstructionMetrics.from_payload(source, payload))
    end)
  end

  test "rejects out-of-range and wrong metric scalar types" do
    malformed_payloads = [
      {"bluesky", Map.put(@payloads["bluesky"], "total_actions", -1)},
      {"bluesky", Map.put(@payloads["bluesky"], "total_actions", @uint32_max + 1)},
      {"bluesky", Map.put(@payloads["bluesky"], "replies", 1.0)},
      {"bluesky", Map.put(@payloads["bluesky"], "truncated", "false")},
      {"ripe_ris", Map.put(@payloads["ripe_ris"], "peer_count", nil)},
      {"solana", Map.put(@payloads["solana"], "first_slot", %{"slot" => 101})},
      {"solana", Map.put(@payloads["solana"], "first_slot", @json_safe_max + 1)},
      {"solana", Map.put(@payloads["solana"], "gap_count", [1])},
      {"solana", Map.put(@payloads["solana"], "truncated", "false")},
      {"drand", Map.put(@payloads["drand"], "round", 42.0)}
    ]

    Enum.each(malformed_payloads, fn {source, payload} ->
      assert InstructionMetrics.from_payload(source, payload) == :error
    end)
  end

  test "rejects missing metrics and oversized collection values before projection" do
    malformed_payloads = [
      {"bluesky", Map.delete(@payloads["bluesky"], "deletes")},
      {"ripe_ris", Map.put(@payloads["ripe_ris"], "announced", List.duplicate(0, 50_000))},
      {"solana", Map.put(@payloads["solana"], "last_slot", %{slot: @uint32_max})},
      {"drand", Map.put(@payloads["drand"], "round", List.duplicate(42, 50_000))}
    ]

    Enum.each(malformed_payloads, fn {source, payload} ->
      assert InstructionMetrics.from_payload(source, payload) == :error
    end)
  end

  test "revalidates source-specific invariants at the stored event boundary" do
    malformed_payloads = [
      {"bluesky", Map.put(@payloads["bluesky"], "window_count", 0)},
      {"bluesky", Map.put(@payloads["bluesky"], "window_span_seconds", 8)},
      {"ripe_ris", Map.put(@payloads["ripe_ris"], "window_span_seconds", 4)},
      {"solana", Map.merge(@payloads["solana"], %{"first_slot" => 106, "last_slot" => 105})},
      {"solana",
       Map.merge(@payloads["solana"], %{
         "slot_count" => 4,
         "first_slot" => 101,
         "last_slot" => 103
       })},
      {"solana", Map.put(@payloads["solana"], "slot_count", 0)},
      {"drand", Map.put(@payloads["drand"], "round", 0)}
    ]

    Enum.each(malformed_payloads, fn {source, payload} ->
      assert InstructionMetrics.from_payload(source, payload) == :error
    end)
  end

  test "denies unsupported sources and non-map payloads without atomizing keys" do
    assert InstructionMetrics.from_payload("wikimedia", @payloads["bluesky"]) == :error
    assert InstructionMetrics.from_payload("future", @payloads["bluesky"]) == :error
    assert InstructionMetrics.from_payload(:bluesky, @payloads["bluesky"]) == :error
    assert InstructionMetrics.from_payload("bluesky", []) == :error
  end
end
