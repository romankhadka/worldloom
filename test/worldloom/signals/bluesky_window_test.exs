defmodule Worldloom.Signals.BlueskyWindowTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.BlueskyWindow

  @fixture "test/support/fixtures/feeds/bluesky_frames.json"
  @uint32_max 4_294_967_295

  test "aggregates only approved public activity counters" do
    frames = read_frames()

    window =
      Enum.reduce(Enum.take(frames, 5), BlueskyWindow.new(~U[2026-08-08 16:00:01Z]), fn
        frame, window ->
          assert {:ok, next_window} = BlueskyWindow.add(window, frame)
          next_window
      end)

    assert BlueskyWindow.flush(window) == %{
             window_start: ~U[2026-08-08 16:00:01Z],
             total_actions: 5,
             original_posts: 3,
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
    assert {:ok, window} = BlueskyWindow.add(window, original)

    future = Map.put(original, "time_us", 1_786_204_805_000_000)

    assert {:flush, completed_window, next_window} =
             BlueskyWindow.add(window, future)

    assert next_window.window_start == ~U[2026-08-08 16:00:05Z]

    late = Map.put(original, "time_us", 1_786_204_804_999_999)
    assert {:ok, completed_window} = BlueskyWindow.add(completed_window, late)

    refute BlueskyWindow.elapsed?(completed_window, ~U[2026-08-08 16:00:05.999999Z])
    assert BlueskyWindow.elapsed?(completed_window, ~U[2026-08-08 16:00:06Z])

    too_old = Map.put(original, "time_us", 1_786_204_800_999_999)

    assert {:drop, :late_event, ^completed_window} =
             BlueskyWindow.add(completed_window, too_old)
  end

  test "saturates counters and marks the aggregate truncated" do
    [original | _rest] = read_frames()

    window = %{
      BlueskyWindow.new(~U[2026-08-08 16:00:01Z])
      | total_actions: @uint32_max,
        original_posts: @uint32_max,
        creates: @uint32_max
    }

    assert {:ok, saturated} = BlueskyWindow.add(window, original)
    assert saturated.total_actions == @uint32_max
    assert saturated.original_posts == @uint32_max
    assert saturated.creates == @uint32_max
    assert saturated.truncated
  end

  test "drops unknown, malformed, account, and identity frames without changing state" do
    frames = read_frames()
    window = BlueskyWindow.new(~U[2026-08-08 16:00:01Z])

    assert {:drop, :unsupported_collection, ^window} =
             BlueskyWindow.add(window, Enum.at(frames, 5))

    assert {:drop, :invalid_timestamp, ^window} =
             BlueskyWindow.add(window, Enum.at(frames, 6))

    assert {:drop, :unsupported_kind, ^window} =
             BlueskyWindow.add(window, Enum.at(frames, 7))

    assert {:drop, :unsupported_kind, ^window} =
             BlueskyWindow.add(window, Enum.at(frames, 8))

    invalid_operation =
      frames
      |> hd()
      |> put_in(["commit", "operation"], "unknown")

    assert {:drop, :unsupported_operation, ^window} =
             BlueskyWindow.add(window, invalid_operation)

    invalid_record =
      frames
      |> hd()
      |> put_in(["commit", "operation"], "delete")
      |> put_in(["commit", "record"], "raw-record")

    assert {:drop, :invalid_record, ^window} =
             BlueskyWindow.add(window, invalid_record)
  end

  test "empty windows stay empty and accepted frames retain no content or identity" do
    [private_frame | _rest] = read_frames()
    empty_window = BlueskyWindow.new(~U[2026-08-08 16:00:01Z])

    assert BlueskyWindow.flush(empty_window) == :empty
    assert {:ok, sanitized_window} = BlueskyWindow.add(empty_window, private_frame)

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
end
