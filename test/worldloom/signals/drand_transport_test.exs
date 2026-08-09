defmodule Worldloom.Signals.DrandTransportTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.DrandTransport

  @finch_events [
    [:finch, :request, :start],
    [:finch, :request, :stop],
    [:finch, :request, :exception]
  ]

  test "streams a bounded HTTPS response without exposing it through Finch telemetry" do
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        @finch_events,
        fn event, measurements, metadata, test_process ->
          send(test_process, {:finch_telemetry, event, measurements, metadata})
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, response} =
             DrandTransport.get(
               "https://api.drand.sh/v2/chains/synthetic/info",
               transport_options(),
               Worldloom.Signals.DrandTransportTest.SuccessfulMint
             )

    assert response.status == 200
    assert Req.Response.get_header(response, "content-type") == ["application/json"]
    assert response.body == ~s({"round":42})

    assert_receive {:mint_connect_options, connect_options}
    assert connect_options[:mode] == :passive
    assert connect_options[:protocols] == [:http1]
    assert connect_options[:log] == false
    assert connect_options[:max_header_list_size] == 16_384
    assert connect_options[:transport_opts] == [timeout: 11, send_timeout: 12]

    assert_receive {:mint_request_headers, request_headers}
    assert {"accept", "application/json"} in request_headers
    assert_receive :mint_connection_closed
    refute_receive {:finch_telemetry, _event, _measurements, _metadata}
  end

  test "halts without retaining a response body beyond 4096 bytes" do
    assert {:error, :unavailable} =
             DrandTransport.get(
               "https://api.drand.sh/v2/chains/synthetic/info",
               transport_options(),
               Worldloom.Signals.DrandTransportTest.OversizedMint
             )

    assert_receive :mint_connection_closed
  end

  test "accepts an exactly 4096-byte response body" do
    assert {:ok, response} =
             DrandTransport.get(
               "https://api.drand.sh/v2/chains/synthetic/info",
               transport_options(),
               Worldloom.Signals.DrandTransportTest.ExactLimitMint
             )

    assert byte_size(response.body) == 4_096
    assert_receive :mint_connection_closed
  end

  test "rejects transport URLs outside the pinned HTTPS shape before connecting" do
    for url <- [
          "http://api.drand.sh/v2/chains/synthetic/info",
          "https://user@example.com/v2/chains/synthetic/info",
          "https://api.drand.sh/v2/chains/synthetic/info#fragment",
          "not a URL"
        ] do
      assert {:error, :unavailable} =
               DrandTransport.get(
                 url,
                 transport_options(),
                 Worldloom.Signals.DrandTransportTest.UnexpectedMint
               )
    end

    refute_receive :mint_connected
  end

  test "collapses request raises and receive exits while closing the connection" do
    for mint <- [
          Worldloom.Signals.DrandTransportTest.RequestRaisesMint,
          Worldloom.Signals.DrandTransportTest.RequestErrorsMint,
          Worldloom.Signals.DrandTransportTest.ReceiveExitsMint,
          Worldloom.Signals.DrandTransportTest.ReceiveErrorsMint
        ] do
      assert {:error, :unavailable} =
               DrandTransport.get(
                 "https://api.drand.sh/v2/chains/synthetic/info",
                 transport_options(),
                 mint
               )

      assert_receive :mint_connection_closed
    end
  end

  test "uses one absolute receive deadline instead of refreshing on partial progress" do
    assert {:error, :unavailable} =
             DrandTransport.get(
               "https://api.drand.sh/v2/chains/synthetic/info",
               transport_options(receive_timeout: 35),
               Worldloom.Signals.DrandTransportTest.PartialProgressMint
             )

    observed_timeouts = collect_receive_timeouts()

    assert length(observed_timeouts) >= 2
    assert hd(observed_timeouts) <= 35
    assert List.last(observed_timeouts) < hd(observed_timeouts)
    assert_receive :mint_connection_closed
  end

  defp transport_options(overrides \\ []) do
    [
      headers: [{"user-agent", "Worldloom/Test"}, {"accept", "application/json"}],
      connect_options: [timeout: 11, transport_opts: [send_timeout: 12]],
      receive_timeout: Keyword.get(overrides, :receive_timeout, 13)
    ]
  end

  defp collect_receive_timeouts(timeouts \\ []) do
    receive do
      {:mint_receive_timeout, timeout} -> collect_receive_timeouts([timeout | timeouts])
    after
      0 -> Enum.reverse(timeouts)
    end
  end

  defmodule SuccessfulMint do
    def connect(:https, "api.drand.sh", 443, options) do
      send(self(), {:mint_connect_options, options})
      {:ok, %{owner: self(), delivered?: false}}
    end

    def request(connection, "GET", "/v2/chains/synthetic/info", headers, nil) do
      send(self(), {:mint_request_headers, headers})
      {:ok, connection, :request}
    end

    def recv(%{delivered?: false} = connection, 0, _timeout) do
      responses = [
        {:status, :request, 200},
        {:headers, :request, [{"content-type", "application/json"}]},
        {:data, :request, ~s({"round":42})},
        {:done, :request}
      ]

      {:ok, %{connection | delivered?: true}, responses}
    end

    def close(connection) do
      send(connection.owner, :mint_connection_closed)
      {:ok, connection}
    end
  end

  defmodule OversizedMint do
    def connect(:https, "api.drand.sh", 443, _options),
      do: {:ok, %{owner: self(), delivered?: false}}

    def request(connection, "GET", "/v2/chains/synthetic/info", _headers, nil),
      do: {:ok, connection, :request}

    def recv(%{delivered?: false} = connection, 0, _timeout) do
      responses = [
        {:status, :request, 200},
        {:headers, :request, [{"content-type", "application/json"}]},
        {:data, :request, String.duplicate("x", 4_096)},
        {:data, :request, "x"},
        {:done, :request}
      ]

      {:ok, %{connection | delivered?: true}, responses}
    end

    def close(connection) do
      send(connection.owner, :mint_connection_closed)
      {:ok, connection}
    end
  end

  defmodule ExactLimitMint do
    def connect(:https, "api.drand.sh", 443, _options),
      do: {:ok, %{owner: self(), delivered?: false}}

    def request(connection, "GET", "/v2/chains/synthetic/info", _headers, nil),
      do: {:ok, connection, :request}

    def recv(%{delivered?: false} = connection, 0, _timeout) do
      responses = [
        {:status, :request, 200},
        {:headers, :request, [{"content-type", "application/json"}]},
        {:data, :request, String.duplicate("x", 4_096)},
        {:done, :request}
      ]

      {:ok, %{connection | delivered?: true}, responses}
    end

    def close(connection) do
      send(connection.owner, :mint_connection_closed)
      {:ok, connection}
    end
  end

  defmodule UnexpectedMint do
    def connect(_scheme, _host, _port, _options) do
      send(self(), :mint_connected)
      {:error, :unexpected_connection}
    end
  end

  defmodule RequestRaisesMint do
    def connect(:https, "api.drand.sh", 443, _options), do: {:ok, %{owner: self()}}
    def request(_connection, "GET", _path, _headers, nil), do: raise("private request error")

    def close(connection) do
      send(connection.owner, :mint_connection_closed)
      {:ok, connection}
    end
  end

  defmodule ReceiveExitsMint do
    def connect(:https, "api.drand.sh", 443, _options), do: {:ok, %{owner: self()}}

    def request(connection, "GET", _path, _headers, nil),
      do: {:ok, connection, :request}

    def recv(_connection, 0, _timeout), do: exit(:private_receive_error)

    def close(connection) do
      send(connection.owner, :mint_connection_closed)
      {:ok, connection}
    end
  end

  defmodule RequestErrorsMint do
    def connect(:https, "api.drand.sh", 443, _options), do: {:ok, %{owner: self()}}

    def request(connection, "GET", _path, _headers, nil),
      do: {:error, connection, :private_request_error}

    def close(connection) do
      send(connection.owner, :mint_connection_closed)
      {:ok, connection}
    end
  end

  defmodule ReceiveErrorsMint do
    def connect(:https, "api.drand.sh", 443, _options), do: {:ok, %{owner: self()}}

    def request(connection, "GET", _path, _headers, nil),
      do: {:ok, connection, :request}

    def recv(connection, 0, _timeout),
      do: {:error, connection, :private_receive_error, []}

    def close(connection) do
      send(connection.owner, :mint_connection_closed)
      {:ok, connection}
    end
  end

  defmodule PartialProgressMint do
    def connect(:https, "api.drand.sh", 443, _options), do: {:ok, %{owner: self()}}

    def request(connection, "GET", _path, _headers, nil),
      do: {:ok, connection, :request}

    def recv(connection, 0, timeout) do
      send(connection.owner, {:mint_receive_timeout, timeout})
      Process.sleep(min(timeout, 10))
      {:ok, connection, []}
    end

    def close(connection) do
      send(connection.owner, :mint_connection_closed)
      {:ok, connection}
    end
  end
end
