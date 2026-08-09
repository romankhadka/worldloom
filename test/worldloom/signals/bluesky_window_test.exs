defmodule Worldloom.Signals.BlueskyWindowTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.BlueskyWindow

  @fixture "test/support/fixtures/feeds/bluesky_frames.json"
  @uint32_max 4_294_967_295
  @receipt_at ~U[2026-08-08 16:01:00Z]

  test "aggregates only approved public activity counters" do
    frames = read_frames()

    window =
      Enum.reduce(Enum.take(frames, 5), BlueskyWindow.new(~U[2026-08-08 16:00:01Z]), fn
        frame, window ->
          assert {:ok, next_window} = BlueskyWindow.add(window, frame, @receipt_at)
          next_window
      end)

    assert BlueskyWindow.flush(window) == %{
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

  test "uses provider time and keeps the crossed window for one second of lateness" do
    [original | _rest] = read_frames()
    window = BlueskyWindow.new(~U[2026-08-08 16:00:01Z])
    assert {:ok, window} = BlueskyWindow.add(window, original, @receipt_at)

    future = Map.put(original, "time_us", 1_786_204_805_000_000)

    assert {:flush, completed_window, next_window} =
             BlueskyWindow.add(window, future, @receipt_at)

    assert next_window.window_start == ~U[2026-08-08 16:00:05Z]

    late = Map.put(original, "time_us", 1_786_204_804_999_999)

    assert {:ok, completed_window} =
             BlueskyWindow.add(completed_window, late, @receipt_at)

    refute BlueskyWindow.elapsed?(completed_window, ~U[2026-08-08 16:00:05.999999Z])
    assert BlueskyWindow.elapsed?(completed_window, ~U[2026-08-08 16:00:06Z])

    too_old = Map.put(original, "time_us", 1_786_204_800_999_999)

    assert {:drop, :late_event, ^completed_window} =
             BlueskyWindow.add(completed_window, too_old, @receipt_at)
  end

  test "accepts replay and future-skew boundaries exactly and rejects one microsecond beyond" do
    [original | _rest] = read_frames()
    receipt_at = ~U[2026-08-08 16:01:01Z]

    replay_boundary = DateTime.add(receipt_at, -60_000_000, :microsecond)
    replay_window = BlueskyWindow.new(replay_boundary)

    assert {:ok, replay_window} =
             BlueskyWindow.add(replay_window, at(original, replay_boundary), receipt_at)

    too_old = DateTime.add(replay_boundary, -1, :microsecond)

    assert {:drop, :timestamp_too_old, ^replay_window} =
             BlueskyWindow.add(replay_window, at(original, too_old), receipt_at)

    future_boundary = DateTime.add(receipt_at, 5_000_000, :microsecond)
    future_window = BlueskyWindow.new(future_boundary)

    assert {:ok, future_window} =
             BlueskyWindow.add(future_window, at(original, future_boundary), receipt_at)

    too_far_in_future = DateTime.add(future_boundary, 1, :microsecond)

    assert {:drop, :timestamp_in_future, ^future_window} =
             BlueskyWindow.add(future_window, at(original, too_far_in_future), receipt_at)
  end

  test "a long outage jumps from an old replay window to the accepted live tail" do
    [original | _rest] = read_frames()
    stale_window = BlueskyWindow.new(~U[2025-08-08 16:00:01Z])
    live_tail = @receipt_at

    assert {:flush, ^stale_window, next_window} =
             BlueskyWindow.add(stale_window, at(original, live_tail), @receipt_at)

    assert next_window.window_start == BlueskyWindow.new(live_tail).window_start
    assert next_window.total_actions == 1
  end

  test "a year-9999 timestamp cannot poison the window before a valid frame" do
    [original | _rest] = read_frames()
    window = BlueskyWindow.new(@receipt_at)
    year_9999 = ~U[9999-12-31 23:59:59Z]

    assert {:drop, :timestamp_in_future, ^window} =
             BlueskyWindow.add(window, at(original, year_9999), @receipt_at)

    assert {:ok, accepted_window} =
             BlueskyWindow.add(window, at(original, @receipt_at), @receipt_at)

    assert accepted_window.window_start == window.window_start
    assert accepted_window.total_actions == 1
  end

  test "requires one valid trusted receipt time for every frame" do
    [original | _rest] = read_frames()
    window = BlueskyWindow.new(@receipt_at)

    assert_raise ArgumentError, "receipt time must be a DateTime", fn ->
      BlueskyWindow.add(window, original, nil)
    end

    refute function_exported?(BlueskyWindow, :add, 2)
  end

  test "record-less post deletes have no category while repost deletes stay reposts" do
    [_original, _reply, _repost, _update, post_delete | _rest] = read_frames()
    window = BlueskyWindow.new(~U[2026-08-08 16:00:01Z])

    assert {:ok, post_window} = BlueskyWindow.add(window, post_delete, @receipt_at)

    assert BlueskyWindow.flush(post_window) == %{
             window_start: ~U[2026-08-08 16:00:01Z],
             total_actions: 1,
             original_posts: 0,
             replies: 0,
             reposts: 0,
             creates: 0,
             updates: 0,
             deletes: 1,
             truncated: false
           }

    repost_delete =
      post_delete
      |> put_in(["commit", "collection"], "app.bsky.feed.repost")

    assert {:ok, repost_window} = BlueskyWindow.add(window, repost_delete, @receipt_at)
    assert repost_window.total_actions == 1
    assert repost_window.deletes == 1
    assert repost_window.reposts == 1
  end

  test "post creates and updates require a map record" do
    [original | _rest] = read_frames()
    window = BlueskyWindow.new(~U[2026-08-08 16:00:01Z])

    for operation <- ["create", "update"], record <- [:missing, "raw-record"] do
      frame =
        original
        |> put_in(["commit", "operation"], operation)
        |> then(fn frame ->
          if record == :missing,
            do: update_in(frame, ["commit"], &Map.delete(&1, "record")),
            else: put_in(frame, ["commit", "record"], record)
        end)

      assert {:drop, :invalid_record, ^window} =
               BlueskyWindow.add(window, frame, @receipt_at)
    end
  end

  test "saturates counters and marks the aggregate truncated" do
    [original | _rest] = read_frames()

    window = %{
      BlueskyWindow.new(~U[2026-08-08 16:00:01Z])
      | total_actions: @uint32_max,
        original_posts: @uint32_max,
        creates: @uint32_max
    }

    assert {:ok, saturated} = BlueskyWindow.add(window, original, @receipt_at)
    assert saturated.total_actions == @uint32_max
    assert saturated.original_posts == @uint32_max
    assert saturated.creates == @uint32_max
    assert saturated.truncated
  end

  test "drops unknown, malformed, account, and identity frames without changing state" do
    frames = read_frames()
    window = BlueskyWindow.new(~U[2026-08-08 16:00:01Z])

    assert {:drop, :unsupported_collection, ^window} =
             BlueskyWindow.add(window, Enum.at(frames, 5), @receipt_at)

    assert {:drop, :invalid_timestamp, ^window} =
             BlueskyWindow.add(window, Enum.at(frames, 6), @receipt_at)

    assert {:drop, :unsupported_kind, ^window} =
             BlueskyWindow.add(window, Enum.at(frames, 7), @receipt_at)

    assert {:drop, :unsupported_kind, ^window} =
             BlueskyWindow.add(window, Enum.at(frames, 8), @receipt_at)

    invalid_operation =
      frames
      |> hd()
      |> put_in(["commit", "operation"], "unknown")

    assert {:drop, :unsupported_operation, ^window} =
             BlueskyWindow.add(window, invalid_operation, @receipt_at)

    invalid_record =
      frames
      |> hd()
      |> put_in(["commit", "operation"], "delete")
      |> put_in(["commit", "record"], "raw-record")

    assert {:drop, :invalid_record, ^window} =
             BlueskyWindow.add(window, invalid_record, @receipt_at)
  end

  test "empty windows stay empty and accepted frames retain no content or identity" do
    [private_frame | _rest] = read_frames()
    empty_window = BlueskyWindow.new(~U[2026-08-08 16:00:01Z])

    assert BlueskyWindow.flush(empty_window) == :empty

    assert {:ok, sanitized_window} =
             BlueskyWindow.add(empty_window, private_frame, @receipt_at)

    inspected = sanitized_window |> inspect() |> String.downcase()

    Enum.each(~w(did handle text uri cid cursor), fn forbidden ->
      refute inspected =~ forbidden
    end)

    Enum.each(
      ~w(synthetic.invalid synthetic-cursor-never-retained synthetic-post-key synthetic-content-id),
      fn private_value -> refute inspected =~ private_value end
    )
  end

  defp read_frames do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp at(frame, %DateTime{} = occurred_at) do
    Map.put(frame, "time_us", DateTime.to_unix(occurred_at, :microsecond))
  end
end
