defmodule Worldloom.Loom.GesturePolicyTest do
  use ExUnit.Case, async: true

  alias Worldloom.Loom.GesturePolicy
  alias Worldloom.Loom.SourceEvent

  @now ~U[2026-08-03 12:30:00.000000Z]
  @identity Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)
  @peer {127, 0, 0, 1}

  test "authorizes exactly the three public gestures with numeric boundary lanes" do
    expectations = [
      {"tug", :tug, 0, "A visitor tugged the living edge"},
      {"knot", :knot, 0.5, "A visitor tied a knot in the weave"},
      {"illuminate", :illuminate, 1.0, "A visitor illuminated a thread"}
    ]

    for {gesture, kind, lane, summary} <- expectations do
      assert {:ok, %SourceEvent{} = event, "fixed-nonce"} =
               GesturePolicy.authorize(%{"gesture" => gesture, "lane" => lane}, context())

      assert event.kind == kind
      assert event.source == :visitor
      assert event.external_id == nil
      assert event.occurred_at == @now
      assert event.lane == lane * 1.0
      assert event.payload == %{"summary" => summary}
      refute inspect(event) =~ @identity
      refute inspect(event) =~ inspect(@peer)
    end
  end

  test "rejects malformed gestures and lanes before consuming rate capacity" do
    test_process = self()
    rate_limiter = fn _identity, _peer, _now_ms -> send(test_process, :rate_consumed) end
    policy_context = context(rate_limiter: rate_limiter)

    invalid_payloads = [
      %{},
      %{"gesture" => "pull", "lane" => 0.5},
      %{"gesture" => :tug, "lane" => 0.5},
      %{"gesture" => "tug", "lane" => "0.5"},
      %{"gesture" => "tug", "lane" => -0.01},
      %{"gesture" => "tug", "lane" => 1.01},
      %{"gesture" => "tug", "lane" => :nan},
      %{"gesture" => "tug", "lane" => :infinity}
    ]

    for payload <- invalid_payloads do
      assert {:error, :invalid, nil} = GesturePolicy.authorize(payload, policy_context)
    end

    refute_receive :rate_consumed
  end

  test "requires the live edge, a valid signed-session identity, and a peer address" do
    test_process = self()
    rate_limiter = fn _identity, _peer, _now_ms -> send(test_process, :rate_consumed) end
    payload = %{"gesture" => "tug", "lane" => 0.5}

    assert {:error, :not_live, nil} =
             GesturePolicy.authorize(
               payload,
               context(live_edge?: false, rate_limiter: rate_limiter)
             )

    assert {:error, :invalid_identity, nil} =
             GesturePolicy.authorize(payload, context(identity: nil, rate_limiter: rate_limiter))

    assert {:error, :invalid_identity, nil} =
             GesturePolicy.authorize(
               payload,
               context(identity: "forged", rate_limiter: rate_limiter)
             )

    assert {:error, :invalid_peer, nil} =
             GesturePolicy.authorize(
               payload,
               context(peer_address: nil, rate_limiter: rate_limiter)
             )

    refute_receive :rate_consumed
  end

  test "returns safe cooldown and peer burst failures" do
    payload = %{"gesture" => "knot", "lane" => 0.25}

    assert {:error, :cooldown, 12} =
             GesturePolicy.authorize(
               payload,
               context(rate_limiter: fn _identity, _peer, _now -> {:error, :cooldown, 12} end)
             )

    assert {:error, :rate_limited, 2} =
             GesturePolicy.authorize(
               payload,
               context(
                 rate_limiter: fn _identity, _peer, _now ->
                   {:error, :rate_limited, 2}
                 end
               )
             )
  end

  test "commits only an authorized event and maps storage errors to unavailable" do
    test_process = self()
    payload = %{"gesture" => "illuminate", "lane" => 0.75}

    committer = fn event, nonce ->
      send(test_process, {:committed, event, nonce})
      {:ok, %{event | external_id: nil}}
    end

    assert {:ok, %SourceEvent{kind: :illuminate}} =
             GesturePolicy.commit(payload, context(committer: committer))

    assert_receive {:committed, committed_event, "fixed-nonce"}
    assert committed_event.payload == %{"summary" => "A visitor illuminated a thread"}

    assert {:error, :unavailable, nil} =
             GesturePolicy.commit(
               payload,
               context(committer: fn _event, _nonce -> {:error, %{private: "changeset"}} end)
             )
  end

  defp context(overrides \\ []) do
    Keyword.merge(
      [
        identity: @identity,
        peer_address: @peer,
        live_edge?: true,
        clock: fn -> @now end,
        nonce: fn -> "fixed-nonce" end,
        rate_limiter: fn _identity, _peer, _now_ms -> :ok end
      ],
      overrides
    )
  end
end
