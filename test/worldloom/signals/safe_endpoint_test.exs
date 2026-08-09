defmodule Worldloom.Signals.SafeEndpointTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.SafeEndpoint

  test "labels an endpoint without credentials, query, fragment, or replay cursor" do
    endpoint =
      "wss://reader:secret@example.net:8443/stream?cursor=private&token=hidden#fragment"

    assert SafeEndpoint.label(endpoint) == "wss://example.net:8443/stream"
  end

  test "uses a fixed label for malformed or relative endpoints" do
    for endpoint <- [nil, 41, "", "/relative", "not a url", "wss:///missing-host"] do
      assert SafeEndpoint.label(endpoint) == "invalid-endpoint"
    end
  end

  test "accepts only absolute secure WebSocket endpoints" do
    assert {:ok, %URI{scheme: "wss", host: "example.net", path: "/stream"}} =
             SafeEndpoint.parse("wss://example.net/stream?cursor=private")

    for endpoint <- [
          "ws://example.net/stream",
          "https://example.net/stream",
          "wss://reader:secret@example.net/stream",
          "wss:///stream",
          "wss://example.net:0/stream",
          "wss://example.net:70000/stream"
        ] do
      assert SafeEndpoint.parse(endpoint) == {:error, :invalid_endpoint}
    end
  end
end
