defmodule Worldloom.Signals.SSEParserTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.SSEParser

  test "parses fields split across arbitrary chunks" do
    chunks = ["id: 4", "2\nevent: up", "date\ndata: {\"ok\"", ":true}\n\n"]

    {frames, remaining} =
      Enum.reduce(chunks, {[], ""}, fn chunk, {frames, buffer} ->
        {parsed, remaining} = SSEParser.push(buffer, chunk)
        {frames ++ parsed, remaining}
      end)

    assert frames == [%{id: "42", event: "update", data: ~s({"ok":true})}]
    assert remaining == ""
  end

  test "supports CRLF, multiline data, comments, and heartbeat-only frames" do
    payload =
      ": keepalive\r\n\r\n" <>
        "id: cursor-1\r\nevent: recentchange\r\ndata: first\r\ndata: second\r\n\r\n" <>
        ": another heartbeat\r\n\r\n"

    assert {[%{id: "cursor-1", event: "recentchange", data: "first\nsecond"}], ""} =
             SSEParser.push("", payload)
  end

  test "retains incomplete frames until a blank line dispatches them" do
    assert {[], "id: 7\ndata: waiting"} = SSEParser.push("", "id: 7\ndata: waiting")

    assert {[%{id: "7", event: nil, data: "waiting"}], ""} =
             SSEParser.push("id: 7\ndata: waiting", "\n\n")
  end

  test "permits a UTF-8 codepoint split across chunks" do
    <<first::binary-size(2), rest::binary>> = "☀"

    assert {[], buffer} = SSEParser.push("", "data: " <> first)

    assert {[%{id: nil, event: nil, data: "☀"}], ""} =
             SSEParser.push(buffer, rest <> "\n\n")
  end

  test "rejects malformed UTF-8 and oversized frames or buffers" do
    assert_raise ArgumentError, ~r/UTF-8/, fn -> SSEParser.push("", <<255, 10, 10>>) end

    oversized = String.duplicate("x", 256 * 1024 + 1)
    assert_raise ArgumentError, ~r/256 KB/, fn -> SSEParser.push("", "data: " <> oversized) end
    assert_raise ArgumentError, ~r/256 KB/, fn -> SSEParser.push("", oversized <> "\n\n") end
  end
end
