defmodule Worldloom.Loom.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.RateLimiter

  @peer {127, 0, 0, 1}
  @salt "fixed-test-rate-limit-salt"

  test "enforces a thirty-second identity cooldown" do
    {limiter, _table} = start_limiter()

    assert :ok = RateLimiter.authorize(limiter, "visitor-a", @peer, 1_000)
    assert {:error, :cooldown, 30} = RateLimiter.authorize(limiter, "visitor-a", @peer, 1_000)

    assert {:error, :cooldown, 1} =
             RateLimiter.authorize(limiter, "visitor-a", @peer, 30_999)

    assert :ok = RateLimiter.authorize(limiter, "visitor-a", @peer, 31_000)
  end

  test "limits a peer burst, refills, and permits independent identities" do
    {limiter, _table} = start_limiter()

    for index <- 1..10 do
      assert :ok = RateLimiter.authorize(limiter, "visitor-#{index}", @peer, 10_000)
    end

    assert {:error, :rate_limited, 1} =
             RateLimiter.authorize(limiter, "visitor-11", @peer, 10_000)

    assert :ok = RateLimiter.authorize(limiter, "visitor-11", @peer, 11_000)
  end

  test "stores only short-lived keyed values and removes expired rows" do
    clock = start_supervised!({Agent, fn -> 1_000 end})
    {limiter, table} = start_limiter(clock: fn -> Agent.get(clock, & &1) end)
    identity = "identity-that-must-not-be-stored"
    peer = {203, 0, 113, 42}

    assert :ok = RateLimiter.authorize(limiter, identity, peer, 1_000)

    encoded_rows = table |> :ets.tab2list() |> inspect()
    refute encoded_rows =~ identity
    refute encoded_rows =~ "203"
    refute encoded_rows =~ inspect(peer)

    Agent.update(clock, fn _now -> 31_001 end)
    send(limiter, :cleanup)
    _synchronized = :sys.get_state(limiter)

    assert :ets.tab2list(table) == []
  end

  defp start_limiter(overrides \\ []) do
    unique = System.unique_integer([:positive])
    table = String.to_atom("rate_limiter_test_table_#{unique}")

    options =
      Keyword.merge(
        [
          name: nil,
          table: table,
          salt: @salt,
          timer: fn _process, _message, _delay -> make_ref() end
        ],
        overrides
      )

    {:ok, limiter} = RateLimiter.start_link(options)
    on_exit(fn -> if Process.alive?(limiter), do: GenServer.stop(limiter) end)
    {limiter, table}
  end
end
