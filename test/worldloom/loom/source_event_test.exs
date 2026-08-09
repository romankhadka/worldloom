defmodule Worldloom.Loom.SourceEventTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.SourceEvent

  @pairs [
    {:wikimedia, :wikimedia},
    {:earthquake, :usgs},
    {:weather, :open_meteo},
    {:tug, :visitor},
    {:knot, :visitor},
    {:illuminate, :visitor},
    {:public_activity, :bluesky},
    {:route_change, :ripe_ris},
    {:slot, :solana},
    {:randomness, :drand}
  ]

  @render_identity String.duplicate("a", 64)
  @uint32_max 4_294_967_295

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

  test "accepts exactly the public aggregate fields for each new source" do
    expected_keys = %{
      bluesky:
        ~w(summary window_count window_span_seconds total_actions original_posts replies reposts creates updates deletes truncated),
      ripe_ris:
        ~w(summary window_count window_span_seconds announced withdrawn ipv4 ipv6 collector_count peer_count truncated),
      solana:
        ~w(summary window_count window_span_seconds slot_count first_slot last_slot gap_count),
      drand: ~w(summary round)
    }

    Enum.each(expected_keys, fn {source, keys} ->
      {kind, ^source} = Enum.find(@pairs, fn {_kind, pair_source} -> pair_source == source end)

      assert {:ok, event} = SourceEvent.new(valid_attributes(kind, source))
      assert event.payload |> Map.keys() |> Enum.sort() == Enum.sort(keys)
    end)
  end

  test "rejects identity-bearing fields from every new aggregate" do
    forbidden_fields = [
      {:public_activity, :bluesky, "did"},
      {:route_change, :ripe_ris, "prefix"},
      {:route_change, :ripe_ris, "peer"},
      {:slot, :solana, "account"},
      {:slot, :solana, "wallet"},
      {:randomness, :drand, "render_identity"}
    ]

    Enum.each(forbidden_fields, fn {kind, source, field} ->
      payload = Map.put(valid_payload(source), field, "must-not-cross-the-boundary")

      assert {:error, {:payload, :invalid_keys}} =
               SourceEvent.new(valid_attributes(kind, source, %{payload: payload}))
    end)
  end

  test "validates bounded window counters and pressure spans" do
    assert {:ok, ordinary} =
             SourceEvent.new(valid_attributes(:public_activity, :bluesky))

    assert ordinary.payload["window_count"] == 1
    assert ordinary.payload["window_span_seconds"] == 4

    pressure_payload =
      valid_payload(:ripe_ris)
      |> Map.merge(%{
        "window_count" => 3,
        "window_span_seconds" => 12,
        "announced" => 4_294_967_295,
        "truncated" => true
      })

    assert {:ok, pressure} =
             SourceEvent.new(
               valid_attributes(:route_change, :ripe_ris, %{payload: pressure_payload})
             )

    assert pressure.payload["window_count"] == 3
    assert pressure.payload["window_span_seconds"] == 12

    invalid_payloads = [
      Map.put(valid_payload(:bluesky), "window_count", 0),
      Map.put(valid_payload(:bluesky), "window_span_seconds", 8),
      Map.put(valid_payload(:bluesky), "total_actions", -1),
      Map.put(valid_payload(:bluesky), "total_actions", 4_294_967_296),
      Map.put(valid_payload(:bluesky), "replies", 1.0),
      Map.put(valid_payload(:bluesky), "truncated", "false")
    ]

    Enum.each(invalid_payloads, fn payload ->
      assert {:error, {:payload, :invalid_shape}} =
               SourceEvent.new(valid_attributes(:public_activity, :bluesky, %{payload: payload}))
    end)
  end

  test "rejects malformed optional Wikimedia window counters" do
    base_payload = %{"summary" => "A bounded public aggregate"}

    invalid_payloads = [
      Map.put(base_payload, "count", false),
      Map.put(base_payload, "count", 0),
      Map.put(base_payload, "total_absolute_byte_delta", -1),
      Map.put(base_payload, "window_count", 1),
      Map.put(base_payload, "window_span_seconds", 4),
      Map.merge(base_payload, %{"window_count" => 2, "window_span_seconds" => 4})
    ]

    Enum.each(invalid_payloads, fn payload ->
      assert {:error, {:payload, :invalid_shape}} =
               SourceEvent.new(valid_attributes(:wikimedia, :wikimedia, %{payload: payload}))
    end)
  end

  test "requires complete new-source payloads" do
    payload = Map.delete(valid_payload(:ripe_ris), "peer_count")

    assert {:error, {:payload, :invalid_keys}} =
             SourceEvent.new(valid_attributes(:route_change, :ripe_ris, %{payload: payload}))
  end

  test "validates ordered Solana slot bounds and bounded counters" do
    assert {:ok, _event} = SourceEvent.new(valid_attributes(:slot, :solana))

    invalid_payloads = [
      Map.put(valid_payload(:solana), "first_slot", -1),
      Map.merge(valid_payload(:solana), %{"first_slot" => 106, "last_slot" => 105}),
      Map.put(valid_payload(:solana), "last_slot", 1.5),
      Map.put(valid_payload(:solana), "slot_count", 4_294_967_296),
      Map.put(valid_payload(:solana), "gap_count", -1)
    ]

    Enum.each(invalid_payloads, fn payload ->
      assert {:error, {:payload, :invalid_shape}} =
               SourceEvent.new(valid_attributes(:slot, :solana, %{payload: payload}))
    end)
  end

  test "bounds each Solana slot endpoint to an unsigned thirty-two-bit integer" do
    first_slot_at_maximum =
      valid_payload(:solana)
      |> Map.merge(%{"first_slot" => @uint32_max, "last_slot" => @uint32_max})

    last_slot_at_maximum =
      valid_payload(:solana)
      |> Map.merge(%{"first_slot" => 0, "last_slot" => @uint32_max})

    assert {:ok, _event} =
             SourceEvent.new(valid_attributes(:slot, :solana, %{payload: first_slot_at_maximum}))

    assert {:ok, _event} =
             SourceEvent.new(valid_attributes(:slot, :solana, %{payload: last_slot_at_maximum}))

    first_slot_overflow =
      valid_payload(:solana)
      |> Map.merge(%{
        "first_slot" => @uint32_max + 1,
        "last_slot" => @uint32_max + 1
      })

    last_slot_overflow =
      valid_payload(:solana)
      |> Map.merge(%{"first_slot" => 0, "last_slot" => @uint32_max + 1})

    assert {:error, {:payload, :invalid_shape}} =
             SourceEvent.new(valid_attributes(:slot, :solana, %{payload: first_slot_overflow}))

    assert {:error, {:payload, :invalid_shape}} =
             SourceEvent.new(valid_attributes(:slot, :solana, %{payload: last_slot_overflow}))
  end

  test "accepts a positive drand round with an ephemeral lowercase beacon identity" do
    assert {:ok, event} = SourceEvent.new(valid_attributes(:randomness, :drand))

    assert event.render_identity == @render_identity
    refute Map.has_key?(event.payload, "render_identity")
    refute Map.has_key?(event.payload, :render_identity)

    invalid_attributes = [
      %{render_identity: nil},
      %{render_identity: String.duplicate("A", 64)},
      %{render_identity: String.duplicate("a", 63)},
      %{render_identity: String.duplicate("g", 64)},
      %{payload: Map.put(valid_payload(:drand), "round", 0)},
      %{payload: Map.put(valid_payload(:drand), "round", 1.0)}
    ]

    Enum.each(invalid_attributes, fn overrides ->
      assert {:error, _reason} =
               SourceEvent.new(valid_attributes(:randomness, :drand, overrides))
    end)
  end

  test "redacts drand render identity from direct and nested inspection" do
    event = SourceEvent.new!(valid_attributes(:randomness, :drand))
    identity_fragment = String.slice(@render_identity, 0, 16)

    direct_inspection = inspect(event)
    nested_inspection = inspect(%{event: event})

    for inspected <- [direct_inspection, nested_inspection] do
      refute inspected =~ @render_identity
      refute inspected =~ identity_fragment
      assert inspected =~ "kind: :randomness"
      assert inspected =~ "source: :drand"
      assert inspected =~ "payload:"
    end

    wikimedia = SourceEvent.new!(valid_attributes(:wikimedia, :wikimedia))
    wikimedia_inspection = inspect(wikimedia)

    assert wikimedia_inspection =~ "kind: :wikimedia"
    assert wikimedia_inspection =~ "source: :wikimedia"
    refute wikimedia_inspection =~ "render_identity"
  end

  test "forbids render identities for every source except drand" do
    Enum.each(Enum.reject(@pairs, fn {_kind, source} -> source == :drand end), fn {kind, source} ->
      assert {:error, {:render_identity, :forbidden}} =
               SourceEvent.new(
                 valid_attributes(kind, source, %{render_identity: @render_identity})
               )
    end)
  end

  test "rejects payloads that are not JSON-safe or exceed sixteen kibibytes" do
    unsafe_payload = %{
      "summary" => "A public signal entered the weave",
      "languages" => self()
    }

    oversized_payload = %{
      "summary" => "A public signal entered the weave",
      "languages" => [String.duplicate("x", 16_384)]
    }

    assert {:error, {:payload, :invalid}} =
             SourceEvent.new(valid_attributes(:wikimedia, :wikimedia, %{payload: unsafe_payload}))

    assert {:error, {:payload, :invalid}} =
             SourceEvent.new(
               valid_attributes(:wikimedia, :wikimedia, %{payload: oversized_payload})
             )
  end

  test "rejects malformed v2 counters before encoding a massive allowed-key value" do
    massive_counter = List.duplicate(0, 50_000)
    payload = Map.put(valid_payload(:bluesky), "total_actions", massive_counter)

    assert {:error, {:payload, :invalid_shape}} =
             SourceEvent.new(valid_attributes(:public_activity, :bluesky, %{payload: payload}))
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

    render_identity = if source == :drand, do: @render_identity, else: nil

    Map.merge(
      %{
        kind: kind,
        source: source,
        external_id: external_id,
        occurred_at: ~U[2026-08-03 12:00:00.000000Z],
        lane: 0.4,
        intensity: 0.6,
        payload: valid_payload(source),
        render_identity: render_identity
      },
      overrides
    )
  end

  defp valid_payload(:bluesky) do
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

  defp valid_payload(:ripe_ris) do
    %{
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
  end

  defp valid_payload(:solana) do
    %{
      "summary" => "Public computation advanced through the weave",
      "window_count" => 1,
      "window_span_seconds" => 4,
      "slot_count" => 4,
      "first_slot" => 101,
      "last_slot" => 105,
      "gap_count" => 1
    }
  end

  defp valid_payload(:drand) do
    %{"summary" => "drand Quicknet round 42", "round" => 42}
  end

  defp valid_payload(_source), do: %{"summary" => "A public signal entered the weave"}
end
