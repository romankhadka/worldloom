defmodule Worldloom.Signals.SocketPrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Worldloom.Signals.BlueskySocket
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.RipeSocket
  alias Worldloom.Signals.SolanaSocket
  alias Worldloom.TestSupport.FakeWebSocketTransport

  test "all source owners redact state and last messages from OTP status" do
    marker = "raw-frame-status-marker"

    status = %{
      state: %{private: marker},
      message: {:text, marker},
      reason: {:error, marker},
      log: [{:in, {:text, marker}}]
    }

    for owner <- [BlueskySocket, RipeSocket, SolanaSocket] do
      formatted = owner.format_status(status)
      refute inspect(formatted) =~ marker
      assert formatted.state == :redacted
      assert formatted.message == :redacted
      assert formatted.reason == :redacted
      assert formatted.log == :redacted
    end
  end

  test "an edge failure during reduction cannot put its raw frame in crash logs or health" do
    marker = "raw-frame-crash-marker"
    previous_trap_exit = Process.flag(:trap_exit, true)
    test_process = self()

    health =
      start_supervised!(
        {HealthRegistry, name: nil, monitor: nil, clock: fn -> ~U[2026-08-08 16:00:03Z] end}
      )

    {:ok, socket} =
      BlueskySocket.start_link(
        name: nil,
        url: "wss://bluesky.example.invalid/socket?query-marker=#{marker}",
        committed_cursor: nil,
        transport: FakeWebSocketTransport,
        transport_options: [owner: test_process],
        buffer: fn _events, _checkpoint -> :ok end,
        health_registry: health,
        clock: fn -> ~U[2026-08-08 16:00:03Z] end,
        random: fn -> 0.5 end,
        timer: fn _destination, _message, _delay -> make_ref() end
      )

    assert_receive {:transport_connect, _endpoint, transport_id}, 500
    send(socket, {:fake_socket, transport_id, [:connected]})
    assert eventually(fn -> HealthRegistry.current(health).bluesky.connection == :connected end)

    health_monitor = Process.monitor(health)
    Process.exit(health, :kill)
    assert_receive {:DOWN, ^health_monitor, :process, ^health, :killed}, 500

    frame = %{
      "time_us" => DateTime.to_unix(~U[2026-08-08 16:00:03Z], :microsecond),
      "kind" => "commit",
      "did" => "did:example:#{marker}",
      "commit" => %{
        "collection" => "app.bsky.feed.post",
        "operation" => "create",
        "rkey" => marker,
        "record" => %{"text" => marker}
      }
    }

    log =
      capture_log(fn ->
        send(socket, {:fake_socket, transport_id, [{:text, Jason.encode!(frame)}]})
        assert_receive {:EXIT, ^socket, _reason}, 500
        Process.sleep(25)
      end)

    Process.flag(:trap_exit, previous_trap_exit)

    refute log =~ marker
  end

  test "detailed edge failures cannot enter health or telemetry" do
    marker = "provider-failure-marker"
    test_process = self()

    health =
      start_supervised!(
        {HealthRegistry, name: nil, monitor: nil, clock: fn -> ~U[2026-08-08 16:00:03Z] end}
      )

    handler_id = "socket-privacy-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:worldloom, :signals, :feed],
          [:worldloom, :signals, :retry],
          [:worldloom, :signals, :health],
          [:worldloom, :signals, :buffer, :depth]
        ],
        fn event, measurements, metadata, owner ->
          send(owner, {:socket_telemetry, event, measurements, metadata})
        end,
        test_process
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    socket =
      start_supervised!(
        {SolanaSocket,
         name: nil,
         url: "wss://solana.example.invalid/socket?query-marker=#{marker}",
         previous_slot: 100,
         transport: FakeWebSocketTransport,
         transport_options: [owner: test_process],
         buffer: fn _events, _checkpoint -> :ok end,
         health_registry: health,
         clock: fn -> ~U[2026-08-08 16:00:03Z] end,
         random: fn -> 0.5 end,
         timer: fn _destination, _message, _delay -> make_ref() end}
      )

    assert_receive {:transport_connect, _endpoint, transport_id}, 500
    send(socket, {:fake_error, transport_id, {:private_failure, marker}})

    assert eventually(fn ->
             observation = HealthRegistry.current(health).solana
             observation.last_reason == :transport and observation.connection == :disconnected
           end)

    refute inspect(HealthRegistry.current(health)) =~ marker
    refute_receive {:socket_telemetry, _event, _measurements, _metadata}, 50
  end

  defp eventually(assertion, attempts \\ 50)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    if assertion.() do
      true
    else
      Process.sleep(5)
      eventually(assertion, attempts - 1)
    end
  end
end
