defmodule Worldloom.Signals.RipeWindowTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.RipeWindow

  @fixture "test/support/fixtures/feeds/ripe_frames.json"
  @receipt_at ~U[2026-08-08 16:00:06Z]
  @uint32_max 4_294_967_295

  test "builds the exact collector discovery and filtered subscription messages" do
    assert RipeWindow.request_rrc_list_message() == %{
             "type" => "request_rrc_list",
             "data" => nil
           }

    response = %{
      "type" => "ris_rrc_list",
      "data" => ["rrc01", "rrc02", "rrc03"]
    }

    assert {:ok, messages} =
             RipeWindow.subscription_messages(["rrc03", "rrc00", "rrc01"], response)

    assert messages == [
             subscription("rrc03"),
             subscription("rrc01")
           ]

    assert Enum.all?(messages, &is_binary(get_in(&1, ["data", "host"])))
  end

  test "maps current RIPE collector hostnames to the configured short allow-list" do
    response = %{
      "type" => "ris_rrc_list",
      "data" => ["rrc00.ripe.net", "rrc01.ripe.net", "rrc02.ripe.net"]
    }

    assert {:ok, messages} =
             RipeWindow.subscription_messages(["rrc02", "rrc00"], response)

    assert messages == [
             subscription("rrc02.ripe.net"),
             subscription("rrc00.ripe.net")
           ]

    [frame | _remaining] = read_frames()

    qualified =
      RipeWindow.authorize(
        RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"]),
        ["rrc00.ripe.net"]
      )

    current_frame = put_in(frame, ["data", "host"], "rrc00.ripe.net")

    assert {:ok, observed} = RipeWindow.add(qualified, current_frame, @receipt_at)
    assert RipeWindow.flush(observed).collector_count == 1
    refute inspect(observed) =~ "rrc00.ripe.net"
  end

  test "rejects invalid collector configuration and malformed list responses" do
    response = %{"type" => "ris_rrc_list", "data" => ["rrc00"]}

    for configured <- [
          [],
          ["rrc00", "rrc00"],
          ["RRC00"],
          ["rrc0"],
          ["rrc00", "rrc01", "rrc02", "rrc03", "rrc04"],
          "rrc00"
        ] do
      assert {:error, :invalid_collectors} =
               RipeWindow.subscription_messages(configured, response)
    end

    for malformed <- [
          %{"type" => "wrong", "data" => ["rrc00"]},
          %{"type" => "ris_rrc_list", "data" => "rrc00"},
          %{"type" => "ris_rrc_list", "data" => ["rrc00", "rrc00"]},
          %{"type" => "ris_rrc_list", "data" => ["rrc00", "rrc00.ripe.net"]},
          %{"type" => "ris_rrc_list", "data" => ["rrc00.example.net"]},
          %{"type" => "ris_rrc_list", "data" => ["RRC00"]},
          %{"type" => "ris_rrc_list", "data" => [nil]},
          %{"type" => "ris_rrc_list", "data" => ["rrc00" | :improper]},
          %{}
        ] do
      assert {:error, :invalid_rrc_list} =
               RipeWindow.subscription_messages(["rrc00"], malformed)
    end

    assert {:error, :no_available_collectors} =
             RipeWindow.subscription_messages(
               ["rrc00"],
               %{"type" => "ris_rrc_list", "data" => ["rrc01"]}
             )
  end

  test "halts collector discovery at the first entry beyond the bounded namespace" do
    complete_namespace =
      for suffix <- 0..99 do
        "rrc#{String.pad_leading(Integer.to_string(suffix), 2, "0")}"
      end

    assert {:ok, messages} =
             RipeWindow.subscription_messages(
               ["rrc99", "rrc00"],
               %{"type" => "ris_rrc_list", "data" => complete_namespace}
             )

    assert messages == [subscription("rrc99"), subscription("rrc00")]

    oversized = complete_namespace ++ List.duplicate("rrc00", 100_000)
    {:reductions, before_reductions} = Process.info(self(), :reductions)

    assert {:error, :invalid_rrc_list} =
             RipeWindow.subscription_messages(
               ["rrc00"],
               %{"type" => "ris_rrc_list", "data" => oversized}
             )

    {:reductions, after_reductions} = Process.info(self(), :reductions)
    assert after_reductions - before_reductions < 50_000

    oversized_config =
      ["rrc00", "rrc01", "rrc02", "rrc03"] ++ List.duplicate("rrc04", 100_000)

    {:reductions, before_reductions} = Process.info(self(), :reductions)

    assert {:error, :invalid_collectors} =
             RipeWindow.subscription_messages(
               oversized_config,
               %{"type" => "ris_rrc_list", "data" => complete_namespace}
             )

    {:reductions, after_reductions} = Process.info(self(), :reductions)
    assert after_reductions - before_reductions < 50_000
  end

  test "new hashes the approved collector allow-list and rejects invalid lists" do
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00", "rrc01"])

    assert window.window_start == ~U[2026-08-08 16:00:02Z]
    assert MapSet.size(window.approved_collector_fingerprints) == 2
    assert MapSet.size(window.observed_collector_fingerprints) == 0
    assert MapSet.size(window.peer_fingerprints) == 0

    assert Enum.all?(window.approved_collector_fingerprints, fn fingerprint ->
             is_binary(fingerprint) and byte_size(fingerprint) == 32
           end)

    refute "rrc00" in window.approved_collector_fingerprints

    for invalid <- [
          [],
          ["rrc00", "rrc00"],
          ["rrc-00"],
          ["rrc00", "rrc01", "rrc02", "rrc03", "rrc04"]
        ] do
      assert_raise ArgumentError,
                   "approved collectors must be one to four unique rrcNN names",
                   fn ->
                     RipeWindow.new(~U[2026-08-08 16:00:02Z], invalid)
                   end
    end

    assert_raise ArgumentError, "window time must be a DateTime", fn ->
      RipeWindow.new(nil, ["rrc00"])
    end
  end

  test "reauthorizes current and pending windows without discarding aggregates" do
    [first | _rest] = read_frames()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00", "rrc01"])
    assert {:ok, current} = RipeWindow.add(window, first, @receipt_at)

    pending_frame =
      first
      |> put_in(["data", "host"], "rrc01")
      |> put_in(["data", "timestamp"], 1_786_204_806.0)

    assert {:ok, with_pending} =
             RipeWindow.add(current, pending_frame, ~U[2026-08-08 16:00:06.500000Z])

    reauthorized = RipeWindow.authorize(with_pending, ["rrc00"])

    assert RipeWindow.flush(reauthorized) == RipeWindow.flush(current)
    assert MapSet.size(reauthorized.approved_collector_fingerprints) == 1
    assert MapSet.size(reauthorized.pending.approved_collector_fingerprints) == 1
    assert RipeWindow.flush(reauthorized.pending).announced == 3

    assert {:drop, :unapproved_collector, ^reauthorized} =
             RipeWindow.add(
               reauthorized,
               pending_frame,
               ~U[2026-08-08 16:00:06.500000Z]
             )
  end

  test "aggregates official flat withdrawals and announcements by prefix occurrence" do
    [first, second | _rest] = read_frames()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00", "rrc01"])

    assert {:ok, window} = RipeWindow.add(window, first, @receipt_at)
    assert {:ok, window} = RipeWindow.add(window, second, @receipt_at)

    assert RipeWindow.flush(window) == %{
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

  test "keeps current and immediate-successor frames separate through close grace" do
    [frame | _rest] = read_frames()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    current_frame = put_timestamp(frame, ~U[2026-08-08 16:00:02Z])
    successor_frame = put_timestamp(frame, ~U[2026-08-08 16:00:06Z])
    late_current_frame = put_timestamp(frame, ~U[2026-08-08 16:00:05.999999Z])

    assert {:ok, window} =
             RipeWindow.add(window, current_frame, ~U[2026-08-08 16:00:05Z])

    assert {:ok, window_with_pending} =
             RipeWindow.add(window, successor_frame, ~U[2026-08-08 16:00:06.500000Z])

    assert {:ok, window_with_pending} =
             RipeWindow.add(
               window_with_pending,
               successor_frame,
               ~U[2026-08-08 16:00:06.600000Z]
             )

    assert RipeWindow.flush(window_with_pending) == public_counts(~U[2026-08-08 16:00:02Z])

    assert {:ok, window_with_pending} =
             RipeWindow.add(
               window_with_pending,
               late_current_frame,
               ~U[2026-08-08 16:00:06.750000Z]
             )

    expected_current =
      public_counts(~U[2026-08-08 16:00:02Z])
      |> Map.merge(%{announced: 6, withdrawn: 4, ipv4: 6, ipv6: 4})

    assert RipeWindow.flush(window_with_pending) == expected_current

    assert {:open, ^window_with_pending} =
             RipeWindow.close(window_with_pending, ~U[2026-08-08 16:00:06.999999Z])

    assert {:flush, ^expected_current, next_window} =
             RipeWindow.close(window_with_pending, ~U[2026-08-08 16:00:07Z])

    assert next_window.window_start == ~U[2026-08-08 16:00:06Z]

    assert RipeWindow.flush(next_window) ==
             public_counts(~U[2026-08-08 16:00:06Z])
             |> Map.merge(%{announced: 6, withdrawn: 4, ipv4: 6, ipv6: 4})

    refute inspect(window_with_pending) =~ "pending"
  end

  test "requires an explicit close before consuming a non-empty elapsed frame" do
    frame = single_prefix_frame()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    assert {:ok, window} =
             RipeWindow.add(window, frame, ~U[2026-08-08 16:00:06.999999Z])

    elapsed_frame = put_timestamp(frame, ~U[2026-08-08 16:00:07Z])

    assert {:close_required, ^window} =
             RipeWindow.add(window, elapsed_frame, ~U[2026-08-08 16:00:07Z])

    assert {:flush, completed, next_window} =
             RipeWindow.close(window, ~U[2026-08-08 16:00:07Z])

    assert completed.announced == 1
    assert next_window.window_start == ~U[2026-08-08 16:00:06Z]

    assert {:ok, retried_window} =
             RipeWindow.add(next_window, elapsed_frame, ~U[2026-08-08 16:00:07Z])

    assert RipeWindow.flush(retried_window).announced == 1
  end

  test "repeated close is deterministic until the caller installs promoted state" do
    frame = single_prefix_frame()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])
    successor = put_timestamp(frame, ~U[2026-08-08 16:00:06Z])

    assert {:ok, window} =
             RipeWindow.add(window, successor, ~U[2026-08-08 16:00:06.500000Z])

    first_close = RipeWindow.close(window, ~U[2026-08-08 16:00:07Z])
    second_close = RipeWindow.close(window, ~U[2026-08-08 16:00:07Z])

    assert first_close == second_close
    assert {:flush, :empty, promoted} = first_close
    assert promoted.window_start == ~U[2026-08-08 16:00:06Z]
    assert RipeWindow.flush(promoted).announced == 1
    assert {:open, ^promoted} = RipeWindow.close(promoted, ~U[2026-08-08 16:00:07Z])
  end

  test "bounds ahead windows and long-outage recovery without skipping pending" do
    frame = single_prefix_frame()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])
    immediate_successor = put_timestamp(frame, ~U[2026-08-08 16:00:06Z])
    window_ahead = put_timestamp(frame, ~U[2026-08-08 16:00:10Z])

    assert {:flush, :empty, recovered_empty} =
             RipeWindow.close(window, ~U[2026-08-08 16:00:22Z])

    assert recovered_empty.window_start == ~U[2026-08-08 16:00:22Z]
    assert RipeWindow.flush(recovered_empty) == :empty

    assert {:drop, :window_ahead, ^window} =
             RipeWindow.add(window, window_ahead, ~U[2026-08-08 16:00:06.500000Z])

    assert {:ok, with_pending} =
             RipeWindow.add(
               window,
               immediate_successor,
               ~U[2026-08-08 16:00:06.500000Z]
             )

    live_frame = put_timestamp(frame, ~U[2026-08-08 16:00:22Z])

    assert {:close_required, ^with_pending} =
             RipeWindow.add(with_pending, live_frame, ~U[2026-08-08 16:00:22Z])

    assert {:flush, :empty, promoted} =
             RipeWindow.close(with_pending, ~U[2026-08-08 16:00:22Z])

    assert promoted.window_start == ~U[2026-08-08 16:00:06Z]
    assert RipeWindow.flush(promoted).announced == 1

    assert {:close_required, ^promoted} =
             RipeWindow.add(promoted, live_frame, ~U[2026-08-08 16:00:22Z])

    assert {:flush, completed_pending, live_window} =
             RipeWindow.close(promoted, ~U[2026-08-08 16:00:22Z])

    assert completed_pending.announced == 1
    assert live_window.window_start == ~U[2026-08-08 16:00:22Z]
    assert RipeWindow.flush(live_window) == :empty

    assert {:ok, live_window} =
             RipeWindow.add(live_window, live_frame, ~U[2026-08-08 16:00:22Z])

    assert RipeWindow.flush(live_window).announced == 1
  end

  test "isolates validation, capacity, and truncation inside pending state" do
    frame = single_prefix_frame()
    current_frame = put_timestamp(frame, ~U[2026-08-08 16:00:02Z])
    successor_frame = put_timestamp(frame, ~U[2026-08-08 16:00:06Z])
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    assert {:ok, current} = RipeWindow.add(window, current_frame, @receipt_at)

    assert {:ok, with_pending} =
             RipeWindow.add(current, successor_frame, ~U[2026-08-08 16:00:06.500000Z])

    invalid_pending =
      put_in(
        successor_frame,
        ["data", "announcements", Access.at(0), "next_hop"],
        "127.1"
      )

    assert {:drop, :invalid_update, ^with_pending} =
             RipeWindow.add(
               with_pending,
               invalid_pending,
               ~U[2026-08-08 16:00:06.500000Z]
             )

    full_peer_set =
      0..2_047
      |> Enum.map(fn index -> :crypto.hash(:sha256, "synthetic-peer-#{index}") end)
      |> MapSet.new()

    full_pending = %{with_pending.pending | peer_fingerprints: full_peer_set}
    pending_at_capacity = %{with_pending | pending: full_pending}
    unseen_peer = put_in(successor_frame, ["data", "peer"], "198.19.0.1")

    assert {:drop, :peer_capacity, isolated_capacity} =
             RipeWindow.add(
               pending_at_capacity,
               unseen_peer,
               ~U[2026-08-08 16:00:06.500000Z]
             )

    refute isolated_capacity.truncated
    assert isolated_capacity.pending.truncated
    assert isolated_capacity.pending.peer_fingerprints == full_peer_set
    assert RipeWindow.flush(isolated_capacity) == RipeWindow.flush(current)

    saturated_pending = %{
      with_pending.pending
      | announced: @uint32_max,
        ipv4: @uint32_max
    }

    pending_at_counter_limit = %{with_pending | pending: saturated_pending}

    assert {:ok, isolated_counters} =
             RipeWindow.add(
               pending_at_counter_limit,
               successor_frame,
               ~U[2026-08-08 16:00:06.500000Z]
             )

    refute isolated_counters.truncated
    assert isolated_counters.pending.announced == @uint32_max
    assert isolated_counters.pending.ipv4 == @uint32_max
    assert isolated_counters.pending.truncated

    groups =
      [announcement("192.0.2.1", ["203.0.113.0/24"])] ++
        List.duplicate(announcement("192.0.2.1", []), 2_047) ++
        [%{"next_hop" => "not-visited", "prefixes" => ["also-not-visited"]}]

    group_capped = put_in(successor_frame, ["data", "announcements"], groups)

    assert {:ok, isolated_groups} =
             RipeWindow.add(
               with_pending,
               group_capped,
               ~U[2026-08-08 16:00:06.500000Z]
             )

    refute isolated_groups.truncated
    assert isolated_groups.pending.truncated
    assert RipeWindow.flush(isolated_groups) == RipeWindow.flush(current)

    assert {:flush, completed_current, promoted_pending} =
             RipeWindow.close(isolated_groups, ~U[2026-08-08 16:00:07Z])

    refute completed_current.truncated
    assert promoted_pending.truncated

    top_inspection = inspect(isolated_groups)
    nested_inspection = inspect(isolated_groups.pending)
    private_fingerprint = isolated_groups.pending.peer_fingerprints |> Enum.at(0) |> inspect()

    refute top_inspection =~ "pending"

    for private_detail <- [
          "approved_collector_fingerprints",
          "observed_collector_fingerprints",
          "peer_fingerprints",
          private_fingerprint
        ] do
      refute nested_inspection =~ private_detail
    end
  end

  test "zero-prefix updates never advance, pend, or require a close" do
    frame =
      single_prefix_frame()
      |> put_in(["data", "announcements"], [])
      |> put_in(["data", "withdrawals"], [])

    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    for occurred_at <- [
          ~U[2026-08-08 16:00:02Z],
          ~U[2026-08-08 16:00:06Z],
          ~U[2026-08-08 16:00:10Z],
          ~U[2026-08-08 16:00:22Z]
        ] do
      receipt_at = Enum.max([occurred_at, ~U[2026-08-08 16:00:06Z]], DateTime)

      assert {:ok, ^window} =
               RipeWindow.add(window, put_timestamp(frame, occurred_at), receipt_at)
    end
  end

  test "accepts exact receipt bounds and rejects one microsecond beyond without poisoning state" do
    [frame | _rest] = read_frames()
    stale_boundary = DateTime.add(@receipt_at, -20_000_000, :microsecond)
    stale_window = RipeWindow.new(stale_boundary, ["rrc00"])

    assert {:close_required, ^stale_window} =
             RipeWindow.add(stale_window, put_timestamp(frame, stale_boundary), @receipt_at)

    one_microsecond_stale = DateTime.add(stale_boundary, -1, :microsecond)

    assert {:drop, :timestamp_too_old, ^stale_window} =
             RipeWindow.add(
               stale_window,
               put_timestamp(frame, one_microsecond_stale),
               @receipt_at
             )

    valid_after_stale = DateTime.add(stale_boundary, 1, :microsecond)

    assert {:close_required, ^stale_window} =
             RipeWindow.add(
               stale_window,
               put_timestamp(frame, valid_after_stale),
               @receipt_at
             )

    future_boundary = DateTime.add(@receipt_at, 5_000_000, :microsecond)
    future_window = RipeWindow.new(future_boundary, ["rrc00"])

    assert {:ok, future_window} =
             RipeWindow.add(future_window, put_timestamp(frame, future_boundary), @receipt_at)

    one_microsecond_future = DateTime.add(future_boundary, 1, :microsecond)

    assert {:drop, :timestamp_in_future, ^future_window} =
             RipeWindow.add(
               future_window,
               put_timestamp(frame, one_microsecond_future),
               @receipt_at
             )

    valid_window = RipeWindow.new(@receipt_at, ["rrc00"])
    poisoned_frame = put_timestamp(frame, ~U[9999-12-31 23:59:59Z])

    assert {:drop, :timestamp_in_future, ^valid_window} =
             RipeWindow.add(valid_window, poisoned_frame, @receipt_at)

    assert {:ok, accepted_window} =
             RipeWindow.add(valid_window, put_timestamp(frame, @receipt_at), @receipt_at)

    assert accepted_window.window_start == valid_window.window_start
  end

  test "rounds fractional Unix seconds to microseconds and rejects malformed times" do
    [frame | _rest] = read_frames()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    fractional = put_in(frame, ["data", "timestamp"], 1_786_204_802.123456)
    assert {:ok, fractional_window} = RipeWindow.add(window, fractional, @receipt_at)
    assert fractional_window.window_start == ~U[2026-08-08 16:00:02Z]

    for timestamp <- ["1786204802", -1, nil, Integer.pow(10, 1_000), 1.0e300] do
      invalid = put_in(frame, ["data", "timestamp"], timestamp)

      assert {:drop, :invalid_timestamp, ^window} =
               RipeWindow.add(window, invalid, @receipt_at)
    end

    assert_raise ArgumentError, "receipt time must be a DateTime", fn ->
      RipeWindow.add(window, frame, nil)
    end
  end

  test "drops unsupported, unapproved, and malformed peers without changing state" do
    [frame, _second, keepalive | _rest] = read_frames()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    assert {:drop, :unsupported_message, ^window} =
             RipeWindow.add(window, keepalive, @receipt_at)

    unapproved = put_in(frame, ["data", "host"], "rrc01")

    assert {:drop, :unapproved_collector, ^window} =
             RipeWindow.add(window, unapproved, @receipt_at)

    for peer <- [nil, "not-an-ip", "127.1", 123, String.duplicate("1", 40)] do
      malformed = put_in(frame, ["data", "peer"], peer)

      assert {:drop, :invalid_peer, ^window} =
               RipeWindow.add(window, malformed, @receipt_at)
    end
  end

  test "hashes peers from canonical packed address bytes" do
    frame = single_prefix_frame()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    expanded =
      put_in(
        frame,
        ["data", "peer"],
        "2001:0db8:0000:0000:0000:0000:0000:0010"
      )

    compressed = put_in(frame, ["data", "peer"], "2001:db8::10")

    assert {:ok, window} = RipeWindow.add(window, expanded, @receipt_at)
    assert {:ok, window} = RipeWindow.add(window, compressed, @receipt_at)

    expected_fingerprint =
      :crypto.hash(
        :sha256,
        <<0x2001::16, 0x0DB8::16, 0::16, 0::16, 0::16, 0::16, 0::16, 0x0010::16>>
      )

    assert window.peer_fingerprints == MapSet.new([expected_fingerprint])
    assert RipeWindow.flush(window).peer_count == 1
  end

  test "validates required base message identity fields then discards them" do
    frame = single_prefix_frame()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    malformed_frames = [
      update_in(frame, ["data"], &Map.delete(&1, "peer_asn")),
      put_in(frame, ["data", "peer_asn"], 64496),
      put_in(frame, ["data", "peer_asn"], ""),
      put_in(frame, ["data", "peer_asn"], "4294967296"),
      put_in(frame, ["data", "peer_asn"], String.duplicate("9", 1_000)),
      update_in(frame, ["data"], &Map.delete(&1, "id")),
      put_in(frame, ["data", "id"], nil),
      put_in(frame, ["data", "id"], "")
    ]

    for malformed <- malformed_frames do
      assert {:drop, :invalid_update, ^window} =
               RipeWindow.add(window, malformed, @receipt_at)
    end

    assert RipeWindow.flush(window) == :empty
  end

  test "treats an absent announcements or withdrawals side as empty" do
    frame = single_prefix_frame()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    announcement_only = update_in(frame, ["data"], &Map.delete(&1, "withdrawals"))
    assert {:ok, announcement_window} = RipeWindow.add(window, announcement_only, @receipt_at)
    assert announcement_window.announced == 1
    assert announcement_window.withdrawn == 0

    withdrawal_only =
      frame
      |> update_in(["data"], &Map.delete(&1, "announcements"))
      |> put_in(["data", "withdrawals"], ["2001:db8:200::/48"])

    assert {:ok, withdrawal_window} = RipeWindow.add(window, withdrawal_only, @receipt_at)
    assert withdrawal_window.announced == 0
    assert withdrawal_window.withdrawn == 1
    assert withdrawal_window.ipv6 == 1
  end

  test "validates traversed next hops and CIDRs atomically" do
    [frame | _rest] = read_frames()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    malformed_frames = [
      put_in(frame, ["data", "announcements", Access.at(1), "next_hop"], "not-an-ip"),
      put_in(frame, ["data", "announcements", Access.at(1), "next_hop"], "127.1"),
      put_in(frame, ["data", "announcements", Access.at(1), "prefixes", Access.at(0)], "bad"),
      put_in(frame, ["data", "announcements", Access.at(1), "prefixes", Access.at(0)], "127.1/8"),
      put_in(frame, ["data", "withdrawals", Access.at(1)], "203.0.113.0/99"),
      put_in(
        frame,
        ["data", "announcements", Access.at(1), "next_hop"],
        String.duplicate("1", 40)
      ),
      put_in(
        frame,
        ["data", "withdrawals", Access.at(1)],
        String.duplicate("1", 40) <> "/128"
      ),
      put_in(
        frame,
        ["data", "withdrawals", Access.at(1)],
        "203.0.113.0/" <> String.duplicate("9", 4)
      ),
      put_in(frame, ["data", "announcements"], %{}),
      put_in(frame, ["data", "withdrawals"], %{})
    ]

    for malformed <- malformed_frames do
      assert {:drop, :invalid_update, ^window} =
               RipeWindow.add(window, malformed, @receipt_at)
    end

    assert RipeWindow.flush(window) == :empty
    assert MapSet.size(window.observed_collector_fingerprints) == 0
    assert MapSet.size(window.peer_fingerprints) == 0
  end

  test "caps collector hashes at four and rejects collectors outside the allow-list" do
    [frame | _rest] = read_frames()
    collectors = ["rrc00", "rrc01", "rrc02", "rrc03"]
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], collectors)

    observed =
      Enum.reduce(collectors, window, fn collector, current ->
        assert {:ok, next} =
                 RipeWindow.add(current, put_in(frame, ["data", "host"], collector), @receipt_at)

        next
      end)

    assert MapSet.size(observed.approved_collector_fingerprints) == 4
    assert MapSet.size(observed.observed_collector_fingerprints) == 4
    assert RipeWindow.flush(observed).collector_count == 4

    assert {:drop, :unapproved_collector, ^observed} =
             RipeWindow.add(observed, put_in(frame, ["data", "host"], "rrc04"), @receipt_at)
  end

  test "caps peer hashes and still accepts a duplicate after capacity" do
    frame = single_prefix_frame()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    full_window =
      Enum.reduce(0..2_047, window, fn index, current ->
        peer = "198.18.#{div(index, 256)}.#{rem(index, 256)}"

        assert {:ok, next} =
                 RipeWindow.add(current, put_in(frame, ["data", "peer"], peer), @receipt_at)

        next
      end)

    assert MapSet.size(full_window.peer_fingerprints) == 2_048

    assert {:drop, :peer_capacity, capacity_window} =
             RipeWindow.add(
               full_window,
               put_in(frame, ["data", "peer"], "198.19.0.1"),
               @receipt_at
             )

    assert capacity_window.truncated
    assert capacity_window.announced == full_window.announced
    assert capacity_window.peer_fingerprints == full_window.peer_fingerprints

    duplicate = put_in(frame, ["data", "peer"], "198.18.0.0")
    assert {:ok, duplicate_window} = RipeWindow.add(capacity_window, duplicate, @receipt_at)
    assert MapSet.size(duplicate_window.peer_fingerprints) == 2_048
    assert duplicate_window.announced == capacity_window.announced + 1
    assert duplicate_window.truncated
  end

  test "stops at the announcement-group cap without touching the unvisited tail" do
    groups =
      [announcement("192.0.2.1", ["203.0.113.0/24"])] ++
        List.duplicate(announcement("192.0.2.1", []), 2_047) ++
        [%{"next_hop" => "not-visited", "prefixes" => ["also-not-visited"]}]

    frame = put_in(single_prefix_frame(), ["data", "announcements"], groups)
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    assert {:ok, capped} = RipeWindow.add(window, frame, @receipt_at)
    assert capped.announced == 1
    assert capped.ipv4 == 1
    assert capped.truncated
  end

  test "applies the prefix cap in announcement-then-withdrawal wire order" do
    announcement_prefixes =
      for index <- 0..2_047 do
        "10.#{div(index, 256)}.#{rem(index, 256)}.0/24"
      end

    frame =
      single_prefix_frame()
      |> put_in(["data", "announcements"], [announcement("192.0.2.1", announcement_prefixes)])
      |> put_in(["data", "withdrawals"], ["not-visited-withdrawal"])

    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    assert {:ok, capped} = RipeWindow.add(window, frame, @receipt_at)
    assert capped.announced == 2_048
    assert capped.withdrawn == 0
    assert capped.ipv4 == 2_048
    assert capped.truncated
  end

  test "does not truncate exactly 2048 prefixes when no input remains" do
    prefixes =
      for index <- 0..2_047 do
        "10.#{div(index, 256)}.#{rem(index, 256)}.0/24"
      end

    frame =
      single_prefix_frame()
      |> put_in(["data", "announcements"], [announcement("192.0.2.1", prefixes)])
      |> put_in(["data", "withdrawals"], [])

    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])

    assert {:ok, exact} = RipeWindow.add(window, frame, @receipt_at)
    assert exact.announced == 2_048
    assert exact.ipv4 == 2_048
    refute exact.truncated
  end

  test "saturates uint32 counters and marks the window truncated" do
    window = %{
      RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])
      | announced: @uint32_max,
        ipv4: @uint32_max
    }

    assert {:ok, saturated} = RipeWindow.add(window, single_prefix_frame(), @receipt_at)
    assert saturated.announced == @uint32_max
    assert saturated.ipv4 == @uint32_max
    assert saturated.truncated
  end

  test "empty windows flush empty and inspection exposes no identifiers or hashes" do
    [frame | _rest] = read_frames()
    window = RipeWindow.new(~U[2026-08-08 16:00:02Z], ["rrc00"])
    assert RipeWindow.flush(window) == :empty

    assert {:ok, sanitized} = RipeWindow.add(window, frame, @receipt_at)
    inspected = inspect(sanitized)

    Enum.each(
      [
        "approved_collector_fingerprints",
        "observed_collector_fingerprints",
        "peer_fingerprints",
        "rrc00",
        "192.0.2.10",
        "64496",
        "synthetic-message-alpha",
        "192.0.2.1",
        "203.0.113.0/24",
        "64496:100",
        "synthetic-raw-bytes-never-retained"
      ],
      fn private_value -> refute inspected =~ private_value end
    )

    output = inspect(RipeWindow.flush(sanitized))
    refute output =~ "rrc00"
    refute output =~ "192.0.2.10"
    refute output =~ "203.0.113.0/24"
  end

  defp subscription(collector) do
    %{
      "type" => "ris_subscribe",
      "data" => %{
        "type" => "UPDATE",
        "host" => collector,
        "socketOptions" => %{"includeRaw" => false, "acknowledge" => true}
      }
    }
  end

  defp public_counts(window_start) do
    %{
      window_start: window_start,
      announced: 3,
      withdrawn: 2,
      ipv4: 3,
      ipv6: 2,
      collector_count: 1,
      peer_count: 1,
      truncated: false
    }
  end

  defp single_prefix_frame do
    %{
      "type" => "ris_message",
      "data" => %{
        "type" => "UPDATE",
        "timestamp" => 1_786_204_802,
        "host" => "rrc00",
        "peer" => "192.0.2.10",
        "peer_asn" => "64496",
        "id" => "synthetic-message-single",
        "announcements" => [announcement("192.0.2.1", ["203.0.113.0/24"])],
        "withdrawals" => []
      }
    }
  end

  defp announcement(next_hop, prefixes) do
    %{"next_hop" => next_hop, "prefixes" => prefixes}
  end

  defp put_timestamp(frame, %DateTime{} = occurred_at) do
    put_in(
      frame,
      ["data", "timestamp"],
      DateTime.to_unix(occurred_at, :microsecond) / 1_000_000
    )
  end

  defp read_frames do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end
end
