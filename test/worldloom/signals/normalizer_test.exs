defmodule Worldloom.Signals.NormalizerTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Signals.Normalizer

  @fixtures "test/support/fixtures/feeds"
  @forbidden ~w(user user_text ip title comment revision server_url)
  @json_safe_max 9_007_199_254_740_991
  @uint32_max 4_294_967_295

  test "normalizes a privacy-preserving Wikimedia bucket" do
    frames = read_fixture("wikimedia_frames.json")

    bucket = %{
      window_start: ~U[2026-08-03 12:00:00Z],
      cursor: "opaque-stream-cursor",
      count: length(frames),
      total_absolute_byte_delta: 45,
      languages: %{"en" => 2, "de" => 1},
      edit_types: %{"edit" => 2, "new" => 1}
    }

    assert {:ok, %SourceEvent{} = event} = Normalizer.wikimedia_bucket(bucket)
    assert event.kind == :wikimedia
    assert event.source == :wikimedia
    assert event.external_id == "wikimedia-window:1785758400:4"
    assert event.occurred_at == ~U[2026-08-03 12:00:00.000000Z]
    assert event.lane >= 0.0 and event.lane <= 1.0
    assert event.intensity >= 0.0 and event.intensity <= 1.0

    assert event.payload == %{
             "summary" => "3 edits moved through 2 languages",
             "window_count" => 1,
             "window_span_seconds" => 4,
             "count" => 3,
             "total_absolute_byte_delta" => 45,
             "languages" => %{"de" => 1, "en" => 2},
             "dominant_edit_type" => "edit"
           }

    refute inspect(event) =~ "opaque-stream-cursor"
    assert private_noise_absent?(event)
  end

  test "normalizes a privacy-preserving Bluesky activity window" do
    window = %{
      window_start: ~U[2026-08-08 16:00:01Z],
      total_actions: 5,
      original_posts: 2,
      replies: 1,
      reposts: 1,
      creates: 3,
      updates: 1,
      deletes: 1,
      truncated: false,
      cursor: "synthetic-private-cursor",
      identity: "did:example:synthetic-private-identity"
    }

    assert {:ok, %SourceEvent{} = event} = Normalizer.bluesky_window(window)
    assert {:ok, repeated_event} = Normalizer.bluesky_window(window)
    assert event.kind == :public_activity
    assert event.source == :bluesky
    assert event.external_id == "bluesky-window:1786204801:4"
    assert event.occurred_at == ~U[2026-08-08 16:00:01.000000Z]
    assert event.lane == repeated_event.lane
    assert event.lane >= 0.0 and event.lane <= 1.0
    assert event.intensity >= 0.0 and event.intensity <= 1.0

    assert event.payload == %{
             "summary" => "5 public Bluesky actions moved through the weave",
             "window_count" => 1,
             "window_span_seconds" => 4,
             "total_actions" => 5,
             "original_posts" => 2,
             "replies" => 1,
             "reposts" => 1,
             "creates" => 3,
             "updates" => 1,
             "deletes" => 1,
             "truncated" => false
           }

    inspected = inspect(event)
    refute inspected =~ "synthetic-private-cursor"
    refute inspected =~ "did:example:synthetic-private-identity"
  end

  test "rejects empty and semantically impossible Bluesky windows" do
    assert {:error, :invalid_window} =
             normalizable_bluesky_window()
             |> Map.merge(%{
               total_actions: 0,
               original_posts: 0,
               creates: 0
             })
             |> Normalizer.bluesky_window()

    assert {:error, :invalid_window} =
             normalizable_bluesky_window()
             |> Map.put(:creates, 2)
             |> Normalizer.bluesky_window()

    assert {:error, :invalid_window} =
             normalizable_bluesky_window()
             |> Map.merge(%{original_posts: 5, replies: 1})
             |> Normalizer.bluesky_window()
  end

  test "requires every Bluesky counter to fit uint32" do
    assert {:error, :invalid_window} =
             normalizable_bluesky_window()
             |> Map.put(:reposts, -1)
             |> Normalizer.bluesky_window()

    assert {:error, :invalid_window} =
             normalizable_bluesky_window()
             |> Map.put(:deletes, 4_294_967_296)
             |> Normalizer.bluesky_window()
  end

  test "accepts saturated truncated Bluesky windows without exact sum equality" do
    uint32_max = 4_294_967_295

    truncated =
      normalizable_bluesky_window()
      |> Map.merge(%{
        total_actions: uint32_max,
        original_posts: uint32_max,
        replies: uint32_max,
        reposts: uint32_max,
        creates: uint32_max,
        updates: uint32_max,
        deletes: uint32_max,
        truncated: true
      })

    assert {:ok, %SourceEvent{} = event} = Normalizer.bluesky_window(truncated)
    assert event.payload["total_actions"] == uint32_max
    assert event.payload["truncated"]

    exactly_accounted =
      Map.merge(truncated, %{creates: uint32_max - 1, updates: 1, deletes: 0})

    assert {:ok, %SourceEvent{}} = Normalizer.bluesky_window(exactly_accounted)

    assert {:error, :invalid_window} =
             truncated
             |> Map.put(:total_actions, uint32_max - 1)
             |> Normalizer.bluesky_window()

    assert {:error, :invalid_window} =
             truncated
             |> Map.merge(%{creates: 0, updates: 0, deletes: 0})
             |> Normalizer.bluesky_window()

    assert {:error, :invalid_window} =
             truncated
             |> Map.merge(%{creates: uint32_max - 2, updates: 1, deletes: 0})
             |> Normalizer.bluesky_window()
  end

  test "normalizes a deterministic privacy-preserving RIPE route window" do
    window =
      normalizable_ripe_window()
      |> Map.merge(%{
        collector: "rrc00-never-retained",
        peer: "192.0.2.10-never-retained",
        prefixes: ["203.0.113.0/24-never-retained"]
      })

    assert {:ok, %SourceEvent{} = event} = Normalizer.ripe_window(window)
    assert {:ok, repeated_event} = Normalizer.ripe_window(window)
    assert event.kind == :route_change
    assert event.source == :ripe_ris
    assert event.external_id == "ripe-window:1786204802:4"
    assert event.occurred_at == ~U[2026-08-08 16:00:02.000000Z]
    assert event.lane == repeated_event.lane
    assert event.intensity == repeated_event.intensity
    assert event.lane >= 0.0 and event.lane <= 1.0
    assert event.intensity >= 0.0 and event.intensity <= 1.0

    assert event.payload == %{
             "summary" => "7 RIPE route changes moved through the weave",
             "window_count" => 1,
             "window_span_seconds" => 4,
             "announced" => 4,
             "withdrawn" => 3,
             "ipv4" => 4,
             "ipv6" => 3,
             "collector_count" => 2,
             "peer_count" => 2,
             "truncated" => false
           }

    inspected = inspect(event)
    refute inspected =~ "rrc00-never-retained"
    refute inspected =~ "192.0.2.10-never-retained"
    refute inspected =~ "203.0.113.0/24-never-retained"
  end

  test "rejects empty and relationally impossible RIPE windows" do
    assert {:error, :invalid_window} =
             normalizable_ripe_window()
             |> Map.merge(%{announced: 0, withdrawn: 0, ipv4: 0, ipv6: 0})
             |> Normalizer.ripe_window()

    assert {:error, :invalid_window} =
             normalizable_ripe_window()
             |> Map.put(:ipv6, 2)
             |> Normalizer.ripe_window()

    assert {:error, :invalid_window} =
             normalizable_ripe_window()
             |> Map.merge(%{ipv4: 0, ipv6: 0})
             |> Normalizer.ripe_window()
  end

  test "requires exact truncated partitions to agree" do
    assert {:error, :invalid_window} =
             normalizable_ripe_window()
             |> Map.merge(%{ipv4: 4, ipv6: 2, truncated: true})
             |> Normalizer.ripe_window()

    assert {:ok, %SourceEvent{}} =
             normalizable_ripe_window()
             |> Map.put(:truncated, true)
             |> Normalizer.ripe_window()
  end

  test "rejects distinct RIPE counts larger than either public partition total" do
    small_window =
      normalizable_ripe_window()
      |> Map.merge(%{
        announced: 1,
        withdrawn: 1,
        ipv4: 1,
        ipv6: 1,
        collector_count: 2,
        peer_count: 2,
        truncated: true
      })

    for count_field <- [:collector_count, :peer_count] do
      assert {:error, :invalid_window} =
               small_window
               |> Map.put(count_field, 3)
               |> Normalizer.ripe_window()
    end
  end

  test "rejects RIPE count and set bounds outside the contract" do
    for invalid <- [
          Map.put(normalizable_ripe_window(), :announced, -1),
          Map.put(normalizable_ripe_window(), :announced, "4"),
          Map.put(normalizable_ripe_window(), :withdrawn, 4_294_967_296),
          Map.put(normalizable_ripe_window(), :ipv4, nil),
          Map.put(normalizable_ripe_window(), :collector_count, 0),
          Map.put(normalizable_ripe_window(), :collector_count, 5),
          Map.put(normalizable_ripe_window(), :peer_count, 0),
          Map.put(normalizable_ripe_window(), :peer_count, 2_049),
          Map.put(normalizable_ripe_window(), :truncated, :yes)
        ] do
      assert {:error, :invalid_window} = Normalizer.ripe_window(invalid)
    end
  end

  test "accepts saturated truncated RIPE windows without relational equality" do
    uint32_max = 4_294_967_295

    truncated =
      normalizable_ripe_window()
      |> Map.merge(%{
        announced: uint32_max,
        withdrawn: uint32_max,
        ipv4: uint32_max,
        ipv6: 1,
        truncated: true
      })

    assert {:ok, %SourceEvent{} = event} = Normalizer.ripe_window(truncated)
    assert event.payload["announced"] == uint32_max
    assert event.payload["truncated"]
  end

  test "accepts only intersecting exact and saturated RIPE total ranges" do
    uint32_max = 4_294_967_295

    compatible =
      normalizable_ripe_window()
      |> Map.merge(%{
        announced: uint32_max - 1,
        withdrawn: 100,
        ipv4: uint32_max,
        ipv6: 50,
        truncated: true
      })

    assert {:ok, %SourceEvent{}} = Normalizer.ripe_window(compatible)

    incompatible =
      compatible
      |> Map.merge(%{
        withdrawn: 40,
        ipv6: 50
      })

    assert {:error, :invalid_window} = Normalizer.ripe_window(incompatible)
  end

  test "normalizes a deterministic privacy-preserving Solana slot window" do
    window =
      normalizable_solana_window()
      |> Map.merge(%{
        account: "synthetic-account-never-retained",
        transaction: "synthetic-transaction-never-retained",
        wallet: "synthetic-wallet-never-retained",
        parent: 104,
        root: 90,
        subscription: 7
      })

    assert {:ok, %SourceEvent{} = event} = Normalizer.solana_window(window)
    assert {:ok, repeated_event} = Normalizer.solana_window(window)
    assert event.kind == :slot
    assert event.source == :solana
    assert event.external_id == "solana-window:1786204803:4"
    assert event.occurred_at == ~U[2026-08-08 16:00:03.000000Z]
    assert event.lane == repeated_event.lane
    assert event.intensity == repeated_event.intensity
    assert event.lane >= 0.0 and event.lane <= 1.0
    assert event.intensity >= 0.0 and event.intensity <= 1.0

    assert event.payload == %{
             "summary" => "3 Solana slots advanced with 2 gaps",
             "window_count" => 1,
             "window_span_seconds" => 4,
             "slot_count" => 3,
             "first_slot" => 101,
             "last_slot" => 105,
             "gap_count" => 2,
             "truncated" => false
           }

    inspected = inspect(event)

    for private_value <-
          ~w(continuity_anchor account transaction wallet parent root subscription synthetic-account-never-retained synthetic-transaction-never-retained synthetic-wallet-never-retained) do
      refute inspected =~ private_value
    end
  end

  test "validates Solana reconnect continuity and exact logical spans" do
    assert {:ok, %SourceEvent{}} =
             normalizable_solana_window()
             |> Map.merge(%{
               slot_count: 1,
               first_slot: 104,
               last_slot: 104,
               gap_count: 3,
               continuity_anchor: 100
             })
             |> Normalizer.solana_window()

    assert {:ok, %SourceEvent{}} =
             normalizable_solana_window()
             |> Map.delete(:continuity_anchor)
             |> Normalizer.solana_window()

    for impossible <- [
          Map.put(normalizable_solana_window(), :gap_count, 1),
          normalizable_solana_window()
          |> Map.delete(:continuity_anchor)
          |> Map.put(:gap_count, 1),
          Map.put(normalizable_solana_window(), :continuity_anchor, 101),
          Map.put(normalizable_solana_window(), :continuity_anchor, -1),
          Map.put(normalizable_solana_window(), :continuity_anchor, @json_safe_max + 1),
          Map.merge(normalizable_solana_window(), %{
            slot_count: 4,
            first_slot: 101,
            last_slot: 103,
            gap_count: 0,
            continuity_anchor: nil
          })
        ] do
      assert {:error, :invalid_window} = Normalizer.solana_window(impossible)
    end
  end

  test "requires one Solana slot exactly when both endpoints are equal" do
    one_slot =
      normalizable_solana_window()
      |> Map.merge(%{
        slot_count: 1,
        first_slot: 104,
        last_slot: 104,
        gap_count: 0,
        continuity_anchor: nil
      })

    malformed_one_slot =
      normalizable_solana_window()
      |> Map.merge(%{
        slot_count: 1,
        first_slot: 101,
        last_slot: 105,
        gap_count: 4,
        continuity_anchor: nil,
        truncated: false
      })

    assert {:ok, %SourceEvent{}} = Normalizer.solana_window(one_slot)
    assert {:ok, %SourceEvent{}} = Normalizer.solana_window(normalizable_solana_window())
    assert {:error, :invalid_window} = Normalizer.solana_window(malformed_one_slot)
  end

  test "accepts only compatible saturated Solana logical ranges" do
    compatible =
      normalizable_solana_window()
      |> Map.merge(%{
        slot_count: @uint32_max,
        first_slot: 1,
        last_slot: @uint32_max + 20,
        gap_count: 10,
        continuity_anchor: 0,
        truncated: true
      })

    assert {:ok, %SourceEvent{}} = Normalizer.solana_window(compatible)

    incompatible = Map.put(compatible, :last_slot, @uint32_max + 5)
    assert {:error, :invalid_window} = Normalizer.solana_window(incompatible)

    fixed_slot_capacity =
      compatible
      |> Map.merge(%{
        gap_count: 0,
        first_slot: 100,
        last_slot: @uint32_max + 99,
        continuity_anchor: 0
      })

    assert {:error, :invalid_window} = Normalizer.solana_window(fixed_slot_capacity)

    valid_gap_overflow =
      compatible
      |> Map.merge(%{
        slot_count: 10,
        first_slot: @uint32_max + 1,
        last_slot: @uint32_max + 11,
        gap_count: @uint32_max,
        continuity_anchor: 0
      })

    assert {:ok, %SourceEvent{}} = Normalizer.solana_window(valid_gap_overflow)

    assert {:error, :invalid_window} =
             normalizable_solana_window()
             |> Map.put(:truncated, true)
             |> Normalizer.solana_window()

    exact_maximum =
      normalizable_solana_window()
      |> Map.merge(%{
        slot_count: @uint32_max,
        first_slot: 0,
        last_slot: @uint32_max - 1,
        gap_count: 0,
        continuity_anchor: nil,
        truncated: false
      })

    assert {:ok, %SourceEvent{}} = Normalizer.solana_window(exact_maximum)

    assert {:error, :invalid_window} =
             exact_maximum
             |> Map.put(:truncated, true)
             |> Normalizer.solana_window()
  end

  test "rejects malformed and out-of-range Solana aggregates" do
    invalid_windows = [
      Map.put(normalizable_solana_window(), :slot_count, 0),
      Map.put(normalizable_solana_window(), :slot_count, @uint32_max + 1),
      Map.put(normalizable_solana_window(), :gap_count, -1),
      Map.put(normalizable_solana_window(), :gap_count, 1.0),
      Map.put(normalizable_solana_window(), :first_slot, -1),
      Map.put(normalizable_solana_window(), :last_slot, @json_safe_max + 1),
      Map.put(normalizable_solana_window(), :last_slot, 105.0),
      Map.merge(normalizable_solana_window(), %{first_slot: 106, last_slot: 105}),
      Map.put(normalizable_solana_window(), :truncated, :yes),
      Map.delete(normalizable_solana_window(), :first_slot),
      nil
    ]

    for invalid <- invalid_windows do
      assert {:error, :invalid_window} = Normalizer.solana_window(invalid)
    end
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
    assert {:error, :invalid_window} = Normalizer.bluesky_window(%{total_actions: 1})
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

  defp normalizable_bluesky_window do
    %{
      window_start: ~U[2026-08-08 16:00:01Z],
      total_actions: 5,
      original_posts: 2,
      replies: 1,
      reposts: 1,
      creates: 3,
      updates: 1,
      deletes: 1,
      truncated: false
    }
  end

  defp normalizable_ripe_window do
    %{
      window_start: ~U[2026-08-08 16:00:02Z],
      announced: 4,
      withdrawn: 3,
      ipv4: 4,
      ipv6: 3,
      collector_count: 2,
      peer_count: 2,
      truncated: false
    }
  end

  defp normalizable_solana_window do
    %{
      window_start: ~U[2026-08-08 16:00:03Z],
      slot_count: 3,
      first_slot: 101,
      last_slot: 105,
      gap_count: 2,
      truncated: false,
      continuity_anchor: 100
    }
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
