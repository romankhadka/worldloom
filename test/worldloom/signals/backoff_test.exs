defmodule Worldloom.Signals.BackoffTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.Backoff

  test "applies deterministic plus or minus twenty percent jitter" do
    assert Backoff.delay(0, 0.0) == 1_000
    assert Backoff.delay(0, 0.5) == 1_000
    assert Backoff.delay(0, 1.0) == 1_200
    assert Backoff.delay(3, 0.0) == 6_400
    assert Backoff.delay(3, 0.5) == 8_000
    assert Backoff.delay(3, 1.0) == 9_600
  end

  test "caps exponential growth and the jittered result" do
    assert Backoff.delay(8, 0.5) == 256_000
    assert Backoff.delay(9, 0.5) == 256_000
    assert Backoff.delay(100, 1.0) == 300_000
    assert Backoff.delay(100, 0.0) == 204_800
  end

  test "rejects invalid attempts and random fractions" do
    assert_raise ArgumentError, fn -> Backoff.delay(-1, 0.5) end
    assert_raise ArgumentError, fn -> Backoff.delay(1, 1.1) end
    assert_raise ArgumentError, fn -> Backoff.delay(1, "0.5") end
  end
end
