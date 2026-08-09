defmodule Worldloom.Signals.SolanaSlotAdapterTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.SolanaSlotAdapter

  @fixture "test/support/fixtures/feeds/solana_slot_frames.json"
  @json_safe_max 9_007_199_254_740_991
  @uint32_max 4_294_967_295

  test "builds the exact parameterless subscription and validates recovery state" do
    assert SolanaSlotAdapter.subscription_message() == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "method" => "slotSubscribe"
           }

    refute Map.has_key?(SolanaSlotAdapter.subscription_message(), "params")

    empty = SolanaSlotAdapter.new(~U[2026-08-08 16:00:03Z], nil)
    recovered = SolanaSlotAdapter.new(~U[2026-08-08 16:00:04Z], 100)

    assert empty.window_start == ~U[2026-08-08 16:00:03Z]
    assert empty.previous_accepted_slot == nil
    assert recovered.window_start == ~U[2026-08-08 16:00:03Z]
    assert recovered.previous_accepted_slot == 100
    assert SolanaSlotAdapter.flush(empty) == :empty

    for prior_slot <- [-1, @json_safe_max + 1, 1.0, "100"] do
      assert_raise ArgumentError, "previous slot must be a JSON-safe non-negative integer", fn ->
        SolanaSlotAdapter.new(~U[2026-08-08 16:00:03Z], prior_slot)
      end
    end

    assert_raise ArgumentError, "window time must be a DateTime", fn ->
      SolanaSlotAdapter.new(nil, nil)
    end
  end

  test "aggregates accepted slots and discards every unknown input field" do
    [first, second, gapped | _rest] = read_frames()
    state = SolanaSlotAdapter.new(~U[2026-08-08 16:00:03Z], 100)

    assert {:ok, state} = SolanaSlotAdapter.add(state, first, ~U[2026-08-08 16:00:03Z])
    assert {:ok, state} = SolanaSlotAdapter.add(state, second, ~U[2026-08-08 16:00:04Z])
    assert {:ok, state} = SolanaSlotAdapter.add(state, gapped, ~U[2026-08-08 16:00:05Z])

    assert SolanaSlotAdapter.flush(state) == %{
             window_start: ~U[2026-08-08 16:00:03Z],
             slot_count: 3,
             first_slot: 101,
             last_slot: 105,
             gap_count: 2,
             truncated: false,
             continuity_anchor: 100
           }

    assert Map.keys(Map.from_struct(state)) |> Enum.sort() ==
             ~w(continuity_anchor first_slot gap_count last_slot pending previous_accepted_slot slot_count truncated window_start)a
             |> Enum.sort()

    inspected = inspect(state)
    output = inspect(SolanaSlotAdapter.flush(state))

    for private_value <-
          ~w(account transaction wallet program token subscription parent root synthetic-account-never-retained synthetic-transaction-never-retained synthetic-wallet-never-retained synthetic-program-never-retained synthetic-token-never-retained) do
      refute inspected =~ private_value
      refute output =~ private_value
    end
  end

  test "accepts only the official safe ordered notification shape" do
    [frame | _rest] = read_frames()
    state = SolanaSlotAdapter.new(~U[2026-08-08 16:00:03Z], nil)

    genesis = notification(0, 0, 0)
    assert {:ok, genesis_state} = SolanaSlotAdapter.add(state, genesis, ~U[2026-08-08 16:00:03Z])
    assert SolanaSlotAdapter.flush(genesis_state).first_slot == 0

    private_extras =
      frame
      |> put_in(["params", "result", "account"], %{"owner" => "never-retained"})
      |> put_in(["params", "wallet"], ["never-retained"])

    assert {:ok, _state} =
             SolanaSlotAdapter.add(state, private_extras, ~U[2026-08-08 16:00:03Z])

    malformed = [
      put_in(frame, ["jsonrpc"], "1.0"),
      put_in(frame, ["method"], "rootNotification"),
      Map.delete(frame, "params"),
      put_in(frame, ["params", "subscription"], -1),
      put_in(frame, ["params", "subscription"], @json_safe_max + 1),
      put_in(frame, ["params", "subscription"], 7.0),
      put_in(frame, ["params", "result", "slot"], -1),
      put_in(frame, ["params", "result", "slot"], @json_safe_max + 1),
      put_in(frame, ["params", "result", "slot"], 101.0),
      put_in(frame, ["params", "result", "parent"], -1),
      put_in(frame, ["params", "result", "root"], @json_safe_max + 1),
      put_in(frame, ["params", "result", "root"], 100.0),
      notification(101, 101, 90),
      notification(101, 100, 101),
      notification(0, 0, 1),
      %{}
    ]

    for invalid <- malformed do
      assert {:drop, :invalid_notification, ^state} =
               SolanaSlotAdapter.add(state, invalid, ~U[2026-08-08 16:00:03Z])
    end

    assert_raise ArgumentError, "receipt time must be a DateTime", fn ->
      SolanaSlotAdapter.add(state, frame, nil)
    end
  end

  test "drops duplicate and backward slots with distinct reasons and unchanged state" do
    [first, _second, _gapped, duplicate, backward] = read_frames()
    state = SolanaSlotAdapter.new(~U[2026-08-08 16:00:03Z], 100)
    assert {:ok, accepted} = SolanaSlotAdapter.add(state, first, ~U[2026-08-08 16:00:03Z])

    duplicate = put_in(duplicate, ["params", "result", "slot"], 101)
    duplicate = put_in(duplicate, ["params", "result", "parent"], 100)

    assert {:drop, :duplicate_slot, ^accepted} =
             SolanaSlotAdapter.add(accepted, duplicate, ~U[2026-08-08 16:00:04Z])

    backward = put_in(backward, ["params", "result", "slot"], 100)
    backward = put_in(backward, ["params", "result", "parent"], 99)

    assert {:drop, :backward_slot, ^accepted} =
             SolanaSlotAdapter.add(accepted, backward, ~U[2026-08-08 16:00:04Z])
  end

  test "holds one successor through grace and closes deterministically for durable retry" do
    [first, second, gapped | _rest] = read_frames()
    state = SolanaSlotAdapter.new(~U[2026-08-08 16:00:03Z], 100)

    assert {:ok, current} =
             SolanaSlotAdapter.add(state, first, ~U[2026-08-08 16:00:03Z])

    assert {:ok, with_pending} =
             SolanaSlotAdapter.add(current, second, ~U[2026-08-08 16:00:07Z])

    assert {:ok, with_pending} =
             SolanaSlotAdapter.add(with_pending, gapped, ~U[2026-08-08 16:00:07.500000Z])

    assert SolanaSlotAdapter.flush(with_pending).last_slot == 101
    refute inspect(with_pending) =~ "pending"
    refute SolanaSlotAdapter.elapsed?(with_pending, ~U[2026-08-08 16:00:07.999999Z])
    assert SolanaSlotAdapter.elapsed?(with_pending, ~U[2026-08-08 16:00:08Z])

    assert {:open, ^with_pending} =
             SolanaSlotAdapter.close(with_pending, ~U[2026-08-08 16:00:07.999999Z])

    elapsed = notification(106, 105, 95)

    assert {:close_required, ^with_pending} =
             SolanaSlotAdapter.add(with_pending, elapsed, ~U[2026-08-08 16:00:08Z])

    first_close = SolanaSlotAdapter.close(with_pending, ~U[2026-08-08 16:00:08Z])
    retry_close = SolanaSlotAdapter.close(with_pending, ~U[2026-08-08 16:00:08Z])

    assert first_close == retry_close
    assert {:flush, completed, promoted} = first_close
    assert completed.first_slot == 101
    assert completed.last_slot == 101
    assert promoted.window_start == ~U[2026-08-08 16:00:07Z]

    assert SolanaSlotAdapter.flush(promoted) == %{
             window_start: ~U[2026-08-08 16:00:07Z],
             slot_count: 2,
             first_slot: 102,
             last_slot: 105,
             gap_count: 2,
             truncated: false,
             continuity_anchor: 101
           }

    assert {:ok, retried} =
             SolanaSlotAdapter.add(promoted, elapsed, ~U[2026-08-08 16:00:08Z])

    assert SolanaSlotAdapter.flush(retried).last_slot == 106
  end

  test "advances a long outage in bounded closes and preserves committed continuity" do
    [first, second | _rest] = read_frames()
    state = SolanaSlotAdapter.new(~U[2026-08-08 16:00:03Z], 100)

    assert {:flush, :empty, recovered_empty} =
             SolanaSlotAdapter.close(state, ~U[2026-08-08 16:00:23Z])

    assert recovered_empty.window_start == ~U[2026-08-08 16:00:23Z]
    assert recovered_empty.previous_accepted_slot == 100
    assert SolanaSlotAdapter.flush(recovered_empty) == :empty

    assert {:ok, current} = SolanaSlotAdapter.add(state, first, ~U[2026-08-08 16:00:03Z])
    assert {:ok, with_pending} = SolanaSlotAdapter.add(current, second, ~U[2026-08-08 16:00:07Z])

    live_frame = notification(110, 109, 100)

    assert {:close_required, ^with_pending} =
             SolanaSlotAdapter.add(with_pending, live_frame, ~U[2026-08-08 16:00:23Z])

    assert {:flush, _completed, promoted} =
             SolanaSlotAdapter.close(with_pending, ~U[2026-08-08 16:00:23Z])

    assert promoted.window_start == ~U[2026-08-08 16:00:07Z]

    assert {:close_required, ^promoted} =
             SolanaSlotAdapter.add(promoted, live_frame, ~U[2026-08-08 16:00:23Z])

    assert {:flush, completed_pending, live_state} =
             SolanaSlotAdapter.close(promoted, ~U[2026-08-08 16:00:23Z])

    assert completed_pending.last_slot == 102
    assert live_state.window_start == ~U[2026-08-08 16:00:23Z]
    assert live_state.previous_accepted_slot == 102
    assert SolanaSlotAdapter.flush(live_state) == :empty

    assert {:ok, live_state} =
             SolanaSlotAdapter.add(live_state, live_frame, ~U[2026-08-08 16:00:23Z])

    assert SolanaSlotAdapter.flush(live_state).gap_count == 7
    assert SolanaSlotAdapter.flush(live_state).continuity_anchor == 102
  end

  test "counts reconnect gaps and saturates aggregate counters independently" do
    recovered = SolanaSlotAdapter.new(~U[2026-08-08 16:00:03Z], 100)
    reconnect_frame = notification(104, 103, 90)

    assert {:ok, recovered} =
             SolanaSlotAdapter.add(recovered, reconnect_frame, ~U[2026-08-08 16:00:03Z])

    assert SolanaSlotAdapter.flush(recovered).gap_count == 3
    assert SolanaSlotAdapter.flush(recovered).continuity_anchor == 100

    slot_saturated = %{
      recovered
      | slot_count: @uint32_max,
        first_slot: 0,
        last_slot: 104,
        previous_accepted_slot: 104,
        truncated: false
    }

    assert {:ok, slot_saturated} =
             SolanaSlotAdapter.add(
               slot_saturated,
               notification(105, 104, 90),
               ~U[2026-08-08 16:00:04Z]
             )

    assert slot_saturated.slot_count == @uint32_max
    assert slot_saturated.gap_count == recovered.gap_count
    assert slot_saturated.previous_accepted_slot == 105
    assert slot_saturated.truncated

    gap_saturated = %{
      recovered
      | gap_count: @uint32_max,
        first_slot: 0,
        last_slot: 104,
        previous_accepted_slot: 104,
        truncated: false
    }

    assert {:ok, gap_saturated} =
             SolanaSlotAdapter.add(
               gap_saturated,
               notification(106, 105, 90),
               ~U[2026-08-08 16:00:04Z]
             )

    assert gap_saturated.slot_count == recovered.slot_count + 1
    assert gap_saturated.gap_count == @uint32_max
    assert gap_saturated.previous_accepted_slot == 106
    assert gap_saturated.truncated
  end

  defp notification(slot, parent, root) do
    %{
      "jsonrpc" => "2.0",
      "method" => "slotNotification",
      "params" => %{
        "subscription" => 7,
        "result" => %{"slot" => slot, "parent" => parent, "root" => root}
      }
    }
  end

  defp read_frames do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end
end
