defmodule Worldloom.Signals.BoundedCounterTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.BoundedCounter

  @uint32_max 4_294_967_295

  test "adds through the unsigned 32-bit boundary and reports saturation" do
    assert BoundedCounter.add(@uint32_max - 1, 1) == {@uint32_max, false}
    assert BoundedCounter.add(@uint32_max, 1) == {@uint32_max, true}
    assert BoundedCounter.add(@uint32_max - 1, 2) == {@uint32_max, true}
  end

  test "rejects invalid counters and increments" do
    assert_raise ArgumentError, fn -> BoundedCounter.add(0, -1) end
    assert_raise ArgumentError, fn -> BoundedCounter.add(0, 1.0) end
    assert_raise ArgumentError, fn -> BoundedCounter.add(-1, 1) end
    assert_raise ArgumentError, fn -> BoundedCounter.add(@uint32_max + 1, 0) end
  end

  test "derives staggered fixed-window starts" do
    assert BoundedCounter.window_start(~U[2026-08-08 12:00:05Z], 4, 1) ==
             ~U[2026-08-08 12:00:05Z]

    assert BoundedCounter.window_start(~U[2026-08-08 12:00:06Z], 4, 1) ==
             ~U[2026-08-08 12:00:05Z]
  end

  test "rejects invalid window arguments" do
    assert_raise ArgumentError, fn -> BoundedCounter.window_start(nil, 4, 1) end

    assert_raise ArgumentError, fn ->
      BoundedCounter.window_start(~U[2026-08-08 12:00:05Z], 0, 0)
    end

    assert_raise ArgumentError, fn ->
      BoundedCounter.window_start(~U[2026-08-08 12:00:05Z], 61, 0)
    end

    assert_raise ArgumentError, fn ->
      BoundedCounter.window_start(~U[2026-08-08 12:00:05Z], 4, -1)
    end

    assert_raise ArgumentError, fn ->
      BoundedCounter.window_start(~U[2026-08-08 12:00:05Z], 4, 4)
    end
  end
end
