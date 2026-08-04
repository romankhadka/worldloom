defmodule Worldloom.Signals.ClientTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.Client

  setup {Req.Test, :verify_on_exit!}

  test "gets decoded JSON with ETag and identifying headers" do
    stub = {__MODULE__, make_ref()}

    Req.Test.expect(stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "user-agent") == [
               "Worldloom/1.0 (+https://github.com/romankhadka/worldloom)"
             ]

      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("old-etag")]

      conn
      |> Plug.Conn.put_resp_header("etag", ~s("new-etag"))
      |> Req.Test.json(%{"features" => []})
    end)

    request = Req.new(plug: {Req.Test, stub})

    assert {:ok, %{status: 200, body: %{"features" => []}, etag: ~s("new-etag")}} =
             Client.get_json(request, etag: ~s("old-etag"))
  end

  test "treats 304 as a successful empty response" do
    stub = {__MODULE__, make_ref()}

    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("etag", ~s("same-etag"))
      |> Plug.Conn.send_resp(304, "")
    end)

    assert {:ok, %{status: 304, body: "", etag: ~s("same-etag")}} =
             Client.get_json(Req.new(plug: {Req.Test, stub}), [])
  end

  test "returns tagged HTTP, decoding, and timeout errors" do
    status_stub = {__MODULE__, make_ref()}
    decode_stub = {__MODULE__, make_ref()}
    timeout_stub = {__MODULE__, make_ref()}

    Req.Test.expect(status_stub, &Plug.Conn.send_resp(&1, 503, "unavailable"))

    Req.Test.expect(decode_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{")
    end)

    Req.Test.expect(timeout_stub, &Req.Test.transport_error(&1, :timeout))

    assert {:error, {:http_status, 503}} =
             Client.get_json(Req.new(plug: {Req.Test, status_stub}), [])

    assert {:error, {:decode, _reason}} =
             Client.get_json(Req.new(plug: {Req.Test, decode_stub}), [])

    assert {:error, {:transport, :timeout}} =
             Client.get_json(Req.new(plug: {Req.Test, timeout_stub}), [])
  end

  test "streams SSE frames synchronously with resume headers and reports disconnect" do
    stub = {__MODULE__, make_ref()}
    test_process = self()

    Req.Test.expect(stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "accept") == ["text/event-stream"]
      assert Plug.Conn.get_req_header(conn, "last-event-id") == ["cursor-40"]

      conn
      |> Plug.Conn.send_chunked(200)
      |> then(fn conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, "id: 41\ndata: one\n\nid: 42\ndata: two\n\n")
        conn
      end)
    end)

    callback = fn frame -> send(test_process, {:frame, frame}) end

    assert {:error, :disconnected} =
             Client.stream_sse(Req.new(plug: {Req.Test, stub}), "cursor-40", callback)

    assert_receive {:frame, %{id: "41", data: "one"}}, 500
    assert_receive {:frame, %{id: "42", data: "two"}}, 500
  end
end
