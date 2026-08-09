defmodule Worldloom.Signals.BlueskyRecoveryTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.BlueskyRecovery

  test "rewinds a valid committed cursor by five seconds and clamps at zero" do
    receipt_at = ~U[2026-08-08 16:00:30Z]
    receipt_cursor = DateTime.to_unix(receipt_at, :microsecond)
    committed_cursor = receipt_cursor - 10_000_000
    replay_cursor = committed_cursor - 5_000_000

    assert {:replay, ^replay_cursor, %BlueskyRecovery{}} =
             BlueskyRecovery.new(committed_cursor, receipt_at)

    assert {:replay, 0, %BlueskyRecovery{}} =
             BlueskyRecovery.new(4_000_000, ~U[1970-01-01 00:00:10Z])
  end

  test "rejects committed observations before consulting overlap fingerprints" do
    receipt_at = ~U[2026-08-08 16:00:30Z]
    committed_cursor = DateTime.to_unix(receipt_at, :microsecond) - 10_000_000
    assert {:replay, _cursor, recovery} = BlueskyRecovery.new(committed_cursor, receipt_at)

    private_identity = "did:example:synthetic-overlap"

    assert {:ok, recovery} =
             BlueskyRecovery.observe(recovery, committed_cursor + 1, private_identity)

    assert {:drop, :committed, ^recovery} =
             BlueskyRecovery.observe(recovery, committed_cursor, private_identity)

    assert {:drop, :committed, ^recovery} =
             BlueskyRecovery.observe(recovery, committed_cursor - 1, "unseen-private-identity")

    assert {:drop, :duplicate, ^recovery} =
             BlueskyRecovery.observe(recovery, committed_cursor + 2, private_identity)
  end

  test "bounds the open overlap window to fixed-size fingerprints" do
    receipt_at = ~U[2026-08-08 16:00:30Z]
    committed_cursor = DateTime.to_unix(receipt_at, :microsecond) - 10_000_000
    assert {:replay, _cursor, recovery} = BlueskyRecovery.new(committed_cursor, receipt_at)

    full_recovery =
      Enum.reduce(1..4_096, recovery, fn index, recovery ->
        assert {:ok, next_recovery} =
                 BlueskyRecovery.observe(
                   recovery,
                   committed_cursor + index,
                   "synthetic-overlap-#{index}"
                 )

        next_recovery
      end)

    assert MapSet.size(full_recovery.fingerprints) == 4_096
    assert Enum.all?(full_recovery.fingerprints, &(byte_size(&1) == 32))

    assert {:drop, :duplicate, ^full_recovery} =
             BlueskyRecovery.observe(
               full_recovery,
               committed_cursor + 4_097,
               "synthetic-overlap-4096"
             )

    assert {:drop, :fingerprint_capacity, ^full_recovery} =
             BlueskyRecovery.observe(
               full_recovery,
               committed_cursor + 4_097,
               "synthetic-overlap-unseen"
             )
  end

  test "selects the live tail and reports invalid checkpoint gaps" do
    receipt_at = ~U[2026-08-08 16:00:30Z]
    receipt_cursor = DateTime.to_unix(receipt_at, :microsecond)
    replay_cursor = receipt_cursor - 65_000_000

    assert {:live_tail, {:gap, :missing_checkpoint}, %BlueskyRecovery{}} =
             BlueskyRecovery.new(nil, receipt_at)

    assert {:live_tail, {:gap, :future_checkpoint}, %BlueskyRecovery{}} =
             BlueskyRecovery.new(receipt_cursor + 1, receipt_at)

    assert {:live_tail, {:gap, :replay_horizon_exceeded}, %BlueskyRecovery{}} =
             BlueskyRecovery.new(receipt_cursor - 60_000_001, receipt_at)

    assert {:replay, ^replay_cursor, %BlueskyRecovery{}} =
             BlueskyRecovery.new(receipt_cursor - 60_000_000, receipt_at)
  end

  test "inspection exposes neither raw cursors nor identity material" do
    receipt_at = ~U[2026-08-08 16:00:30Z]
    committed_cursor = DateTime.to_unix(receipt_at, :microsecond) - 10_000_000
    assert {:replay, _cursor, recovery} = BlueskyRecovery.new(committed_cursor, receipt_at)

    private_identity = "did:example:synthetic-private-inspection"

    assert {:ok, recovery} =
             BlueskyRecovery.observe(recovery, committed_cursor + 1, private_identity)

    inspected = inspect(recovery)
    refute inspected =~ Integer.to_string(committed_cursor)
    refute inspected =~ private_identity
    refute inspected =~ "fingerprints"
  end
end
