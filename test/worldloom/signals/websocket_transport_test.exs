defmodule Worldloom.Signals.WebSocketTransportTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Worldloom.Signals.WebSocketTransport
  alias Worldloom.TestSupport.WebSocketFixtureServer

  @ca_file Path.expand("test/support/fixtures/tls/localhost_ca.pem")

  test "establishes trusted local WSS and fails closed for trust or hostname errors" do
    server = start_supervised!({WebSocketFixtureServer, test_process: self()})

    assert {:ok, transport} =
             WebSocketTransport.connect(WebSocketFixtureServer.endpoint(server),
               cacertfile: @ca_file
             )

    assert {:ok, connected, [:connected]} = await_transport_event(transport)
    assert WebSocketTransport.connected?(connected)
    assert_receive {:fixture_connected, _connection_process}, 500

    assert {:error, :tls} =
             WebSocketTransport.connect(WebSocketFixtureServer.endpoint(server))

    assert {:error, :tls} =
             WebSocketTransport.connect(WebSocketFixtureServer.endpoint(server, "127.0.0.1"),
               cacertfile: @ca_file
             )
  end

  test "assembles a split upgrade exactly once" do
    server = start_supervised!({WebSocketFixtureServer, test_process: self()})

    assert {:ok, transport} =
             WebSocketTransport.connect(WebSocketFixtureServer.endpoint(server),
               cacertfile: @ca_file
             )

    assert {:ok, connection, responses} = receive_mint_responses(transport)

    {connected, events} =
      Enum.reduce(responses, {%{transport | conn: connection}, []}, fn response,
                                                                       {current, events} ->
        assert {:ok, next, next_events} =
                 WebSocketTransport.consume_responses(current, [response])

        {next, events ++ next_events}
      end)

    assert events == [:connected]
    assert WebSocketTransport.connected?(connected)

    assert {:ok, unchanged, []} =
             WebSocketTransport.consume_responses(connected, [
               {:done, connected.request_ref}
             ])

    assert unchanged == connected

    stale_reference = make_ref()

    assert {:ok, stale_ignored, []} =
             WebSocketTransport.consume_responses(connected, [
               {:status, stale_reference, 101},
               {:headers, stale_reference, [{"private", "discarded"}]},
               {:data, stale_reference, "private-body"},
               {:done, stale_reference}
             ])

    assert stale_ignored == connected
  end

  test "reassembles TCP chunks and WebSocket fragments into one application frame" do
    {_server, connected, _connection_process} = connected_transport()
    first_fragment = server_frame(0x1, "hel", false)
    continuation = server_frame(0x0, "lo", true)
    split_at = byte_size(first_fragment) - 1
    <<first_chunk::binary-size(^split_at), second_chunk::binary>> = first_fragment

    assert {:ok, chunked, []} = WebSocketTransport.decode_data(connected, first_chunk)

    assert {:ok, fragmented, []} =
             WebSocketTransport.decode_data(chunked, second_chunk)

    assert {:ok, fragmented, [{:ping, "pulse"}]} =
             WebSocketTransport.decode_data(fragmented, server_frame(0x9, "pulse", true))

    assert {:ok, _complete, [{:text, "hello"}]} =
             WebSocketTransport.decode_data(fragmented, continuation)
  end

  test "echoes ping payloads and acknowledges close before clearing connection state" do
    {_server, connected, fixture_connection} = connected_transport()
    send(fixture_connection, {:push, {:ping, "pulse"}})

    assert {:ok, pinged, [{:ping, "pulse"}]} = await_transport_event(connected)
    assert {:ok, ponged} = WebSocketTransport.send_frame(pinged, {:pong, "pulse"})
    assert_receive {:fixture_control, :pong, "pulse"}, 500

    send(fixture_connection, {:close, 1_000, "done"})
    assert {:ok, closing, [{:close, 1_000, "done"}]} = await_transport_event(ponged)
    assert WebSocketTransport.connected?(closing)
    assert {:ok, closed} = WebSocketTransport.acknowledge_close(closing, 1_000)
    refute WebSocketTransport.connected?(closed)
  end

  test "rejects complete oversized frames and batches above one hundred frames" do
    {_server, connected, _fixture_connection} = connected_transport()

    assert {:error, :oversized, oversized_state} =
             WebSocketTransport.decode_data(
               connected,
               server_frame(0x1, String.duplicate("x", 262_145), true)
             )

    assert WebSocketTransport.connected?(oversized_state)

    one_batch =
      1..101
      |> Enum.map(fn index -> server_frame(0x1, Integer.to_string(index), true) end)
      |> IO.iodata_to_binary()

    assert {:error, :frame_limit, _bounded_state} =
             WebSocketTransport.decode_data(connected, one_batch)
  end

  test "maps arbitrary transport details to fixed coarse reasons" do
    private_markers = [
      "frame-secret",
      "cursor-secret",
      "wss://user:pass@example.net/socket?token=secret",
      {"authorization", "Bearer secret"},
      %{"body" => "provider-secret"}
    ]

    for marker <- private_markers do
      assert WebSocketTransport.coarse_error(marker) == :transport
    end

    assert WebSocketTransport.coarse_error(%Mint.TransportError{reason: :timeout}) == :timeout
    assert WebSocketTransport.coarse_error(%Mint.WebSocketError{}) == :protocol
  end

  test "never accepts caller options that weaken transport policy" do
    server = start_supervised!({WebSocketFixtureServer, test_process: self()})
    endpoint = WebSocketFixtureServer.endpoint(server)

    for options <- [
          [verify: :verify_none],
          [log: true],
          [mode: :passive],
          [protocols: [:http2]],
          [max_header_list_size: :infinity],
          [timeout: :infinity]
        ] do
      assert WebSocketTransport.connect(endpoint, options) == {:error, :invalid_options}
    end
  end

  defp connected_transport do
    server = start_supervised!({WebSocketFixtureServer, test_process: self()})

    assert {:ok, transport} =
             WebSocketTransport.connect(WebSocketFixtureServer.endpoint(server),
               cacertfile: @ca_file
             )

    assert {:ok, connected, [:connected]} = await_transport_event(transport)
    assert_receive {:fixture_connected, fixture_connection}, 500
    {server, connected, fixture_connection}
  end

  defp await_transport_event(transport) do
    receive do
      message ->
        case WebSocketTransport.stream(transport, message) do
          {:ok, updated, []} ->
            await_transport_event(updated)

          :unknown ->
            response = await_transport_event(transport)
            send(self(), message)
            response

          response ->
            response
        end
    after
      1_000 -> flunk("expected a WebSocket transport event")
    end
  end

  defp receive_mint_responses(transport) do
    receive do
      message ->
        case Mint.WebSocket.stream(transport.conn, message) do
          {:ok, connection, []} ->
            receive_mint_responses(%{transport | conn: connection})

          {:ok, connection, responses} ->
            {:ok, connection, responses}

          :unknown ->
            response = receive_mint_responses(transport)
            send(self(), message)
            response
        end
    after
      1_000 -> flunk("expected a Mint response")
    end
  end

  defp server_frame(opcode, payload, final?) when byte_size(payload) < 126 do
    fin = if final?, do: 0x80, else: 0x00
    <<fin ||| opcode, byte_size(payload), payload::binary>>
  end

  defp server_frame(opcode, payload, final?) when byte_size(payload) <= 65_535 do
    fin = if final?, do: 0x80, else: 0x00
    <<fin ||| opcode, 126, byte_size(payload)::unsigned-big-16, payload::binary>>
  end

  defp server_frame(opcode, payload, final?) do
    fin = if final?, do: 0x80, else: 0x00
    <<fin ||| opcode, 127, byte_size(payload)::unsigned-big-64, payload::binary>>
  end
end
