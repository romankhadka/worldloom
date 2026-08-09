defmodule Worldloom.Signals.WebSocketTransport do
  require Mint.HTTP

  alias Worldloom.Signals.SafeEndpoint

  @derive {Inspect, except: [:conn, :websocket, :status, :response_headers]}
  defstruct [
    :conn,
    :request_ref,
    :websocket,
    :status,
    :response_headers,
    :endpoint_label,
    :upgrade_deadline
  ]

  @type t :: %__MODULE__{
          conn: Mint.HTTP.t() | nil,
          request_ref: reference() | nil,
          websocket: Mint.WebSocket.t() | nil,
          status: non_neg_integer() | nil,
          response_headers: Mint.Types.headers() | nil,
          endpoint_label: String.t(),
          upgrade_deadline: integer() | nil
        }

  @type event :: :connected | Mint.WebSocket.frame()
  @type reason ::
          :invalid_endpoint
          | :invalid_options
          | :tls
          | :timeout
          | :transport
          | :upgrade
          | :protocol
          | :oversized
          | :frame_limit
          | :closed

  @allowed_options [:cacertfile, :cacerts]
  @connect_timeout 5_000
  @send_timeout 5_000
  @upgrade_timeout 5_000
  @maximum_header_bytes 16_384
  @maximum_frame_bytes 262_144
  @maximum_frames_per_message 100

  @spec connect(term(), keyword()) :: {:ok, t()} | {:error, reason()}
  def connect(endpoint, options \\ []) do
    with :ok <- validate_options(options),
         {:ok, uri} <- SafeEndpoint.parse(endpoint),
         {:ok, connection} <- connect_http(uri, options),
         {:ok, connection, request_ref} <- upgrade(connection, uri) do
      {:ok,
       %__MODULE__{
         conn: connection,
         request_ref: request_ref,
         websocket: nil,
         status: nil,
         response_headers: nil,
         endpoint_label: SafeEndpoint.label(endpoint),
         upgrade_deadline: System.monotonic_time(:millisecond) + @upgrade_timeout
       }}
    else
      {:error, :invalid_options} = error ->
        error

      {:error, :invalid_endpoint} = error ->
        error

      {:error, connection, reason} ->
        close_connection_safely(connection)
        {:error, coarse_error(reason)}

      {:error, reason} ->
        {:error, connect_error(reason)}
    end
  end

  @spec stream(t(), term()) :: {:ok, t(), [event()]} | {:error, reason(), t()} | :unknown
  def stream(%__MODULE__{conn: nil}, _message), do: :unknown

  def stream(%__MODULE__{} = transport, message) do
    cond do
      upgrade_expired?(transport) ->
        {:error, :timeout, transport}

      not Mint.HTTP.is_connection_message(transport.conn, message) ->
        :unknown

      true ->
        stream_connection_message(transport, message)
    end
  end

  @doc false
  @spec consume_responses(t(), [term()]) ::
          {:ok, t(), [event()]} | {:error, reason(), t()}
  def consume_responses(%__MODULE__{} = transport, responses) when is_list(responses) do
    Enum.reduce_while(responses, {:ok, transport, []}, fn response, {:ok, current, events} ->
      case consume_response(current, response) do
        {:ok, updated, next_events} ->
          combined_events = events ++ next_events

          if frame_count(combined_events) > @maximum_frames_per_message do
            {:halt, {:error, :frame_limit, updated}}
          else
            {:cont, {:ok, updated, combined_events}}
          end

        {:error, reason, updated} ->
          {:halt, {:error, reason, updated}}
      end
    end)
  end

  @doc false
  @spec decode_data(t(), binary()) ::
          {:ok, t(), [Mint.WebSocket.frame()]} | {:error, reason(), t()}
  def decode_data(%__MODULE__{websocket: nil} = transport, _data),
    do: {:error, :protocol, transport}

  def decode_data(%__MODULE__{} = transport, data) when is_binary(data) do
    case Mint.WebSocket.decode(transport.websocket, data) do
      {:ok, websocket, frames} ->
        updated = %{transport | websocket: websocket}

        cond do
          length(frames) > @maximum_frames_per_message ->
            {:error, :frame_limit, updated}

          Enum.any?(frames, &oversized_frame?/1) ->
            {:error, :oversized, updated}

          true ->
            {:ok, updated, frames}
        end

      {:error, websocket, _reason} ->
        {:error, :protocol, %{transport | websocket: websocket}}
    end
  end

  def decode_data(%__MODULE__{} = transport, _data), do: {:error, :protocol, transport}

  @spec send_frame(t(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) ::
          {:ok, t()} | {:error, reason(), t()}
  def send_frame(%__MODULE__{conn: nil} = transport, _frame),
    do: {:error, :closed, transport}

  def send_frame(%__MODULE__{websocket: nil} = transport, _frame),
    do: {:error, :protocol, transport}

  def send_frame(%__MODULE__{} = transport, frame) do
    with {:ok, websocket, encoded} <- Mint.WebSocket.encode(transport.websocket, frame),
         updated = %{transport | websocket: websocket},
         {:ok, connection} <-
           Mint.WebSocket.stream_request_body(updated.conn, updated.request_ref, encoded) do
      {:ok, %{updated | conn: connection}}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, coarse_error(reason), %{transport | websocket: websocket}}

      {:error, connection, reason} ->
        {:error, coarse_error(reason), %{transport | conn: connection}}
    end
  end

  @spec acknowledge_close(t(), non_neg_integer() | nil) :: {:ok, t()}
  def acknowledge_close(%__MODULE__{} = transport, code) do
    acknowledgement = if is_integer(code), do: {:close, code, ""}, else: :close

    case send_frame(transport, acknowledgement) do
      {:ok, acknowledged} -> {:ok, close_connection(acknowledged)}
      {:error, _reason, failed} -> {:ok, close_connection(failed)}
    end
  end

  @spec close(t()) :: t()
  def close(%__MODULE__{} = transport) do
    case send_frame(transport, :close) do
      {:ok, closing} -> close_connection(closing)
      {:error, _reason, failed} -> close_connection(failed)
    end
  end

  @spec connected?(t()) :: boolean()
  def connected?(%__MODULE__{conn: connection, websocket: websocket}),
    do: not is_nil(connection) and not is_nil(websocket)

  @spec connection_message?(t(), term()) :: boolean()
  def connection_message?(%__MODULE__{conn: nil}, _message), do: false

  def connection_message?(%__MODULE__{} = transport, message),
    do: Mint.HTTP.is_connection_message(transport.conn, message)

  @spec coarse_error(term()) :: reason()
  def coarse_error(%Mint.TransportError{reason: :timeout}), do: :timeout
  def coarse_error(%Mint.WebSocket.UpgradeFailureError{}), do: :upgrade
  def coarse_error(%Mint.WebSocketError{}), do: :protocol
  def coarse_error(:timeout), do: :timeout
  def coarse_error(_reason), do: :transport

  defp connect_http(uri, options) do
    transport_options =
      [
        verify: :verify_peer,
        server_name_indication: String.to_charlist(uri.host),
        timeout: @connect_timeout,
        send_timeout: @send_timeout
      ] ++ trust_options(options)

    Mint.HTTP.connect(:https, uri.host, uri.port,
      hostname: uri.host,
      protocols: [:http1],
      mode: :active,
      log: false,
      max_header_list_size: @maximum_header_bytes,
      transport_opts: transport_options
    )
  end

  defp upgrade(connection, uri) do
    Mint.WebSocket.upgrade(:wss, connection, request_path(uri), [])
  end

  defp request_path(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if is_binary(uri.query), do: path <> "?" <> uri.query, else: path
  end

  defp validate_options(options) when is_list(options) do
    valid_keys? = Keyword.keyword?(options) and Keyword.keys(options) -- @allowed_options == []

    valid_values? =
      Enum.all?(options, fn
        {:cacertfile, path} -> is_binary(path) and path != ""
        {:cacerts, certificates} -> is_list(certificates) and certificates != []
        _invalid -> false
      end)

    if valid_keys? and valid_values?, do: :ok, else: {:error, :invalid_options}
  end

  defp validate_options(_options), do: {:error, :invalid_options}

  defp trust_options(options) do
    Enum.map(options, fn
      {:cacertfile, path} -> {:cacertfile, String.to_charlist(path)}
      {:cacerts, certificates} -> {:cacerts, certificates}
    end)
  end

  defp connect_error(%Mint.TransportError{reason: :timeout}), do: :timeout
  defp connect_error(%Mint.TransportError{}), do: :tls
  defp connect_error(reason), do: coarse_error(reason)

  defp stream_connection_message(transport, message) do
    case Mint.WebSocket.stream(transport.conn, message) do
      {:ok, connection, responses} ->
        consume_responses(%{transport | conn: connection}, responses)

      {:error, connection, reason, responses} ->
        updated = %{transport | conn: connection}

        case consume_responses(updated, responses) do
          {:ok, reduced, _events} -> {:error, coarse_error(reason), reduced}
          {:error, response_reason, reduced} -> {:error, response_reason, reduced}
        end

      :unknown ->
        :unknown
    end
  end

  defp consume_response(%__MODULE__{request_ref: request_ref} = transport, {
         :status,
         request_ref,
         status
       }),
       do: {:ok, %{transport | status: status}, []}

  defp consume_response(%__MODULE__{request_ref: request_ref} = transport, {
         :headers,
         request_ref,
         headers
       }),
       do: {:ok, %{transport | response_headers: headers}, []}

  defp consume_response(
         %__MODULE__{request_ref: request_ref, websocket: nil} = transport,
         {:done, request_ref}
       ) do
    case Mint.WebSocket.new(
           transport.conn,
           request_ref,
           transport.status,
           transport.response_headers || [],
           mode: :active
         ) do
      {:ok, connection, websocket} ->
        {:ok,
         %{
           transport
           | conn: connection,
             websocket: websocket,
             status: nil,
             response_headers: nil,
             upgrade_deadline: nil
         }, [:connected]}

      {:error, connection, _reason} ->
        {:error, :upgrade, %{transport | conn: connection}}
    end
  end

  defp consume_response(%__MODULE__{request_ref: request_ref} = transport, {
         :data,
         request_ref,
         data
       }),
       do: decode_data(transport, data)

  defp consume_response(%__MODULE__{request_ref: request_ref} = transport, {
         :error,
         request_ref,
         reason
       }),
       do: {:error, coarse_error(reason), transport}

  defp consume_response(transport, _response), do: {:ok, transport, []}

  defp oversized_frame?({type, payload}) when type in [:text, :binary, :ping, :pong],
    do: byte_size(payload) > @maximum_frame_bytes

  defp oversized_frame?({:close, _code, reason}) when is_binary(reason),
    do: byte_size(reason) > @maximum_frame_bytes

  defp oversized_frame?(_frame), do: false

  defp frame_count(events), do: Enum.count(events, &(&1 != :connected))

  defp upgrade_expired?(%__MODULE__{websocket: nil, upgrade_deadline: deadline})
       when is_integer(deadline),
       do: System.monotonic_time(:millisecond) > deadline

  defp upgrade_expired?(_transport), do: false

  defp close_connection(%__MODULE__{conn: nil} = transport), do: transport

  defp close_connection(%__MODULE__{} = transport) do
    close_connection_safely(transport.conn)

    %{
      transport
      | conn: nil,
        request_ref: nil,
        websocket: nil,
        status: nil,
        response_headers: nil,
        upgrade_deadline: nil
    }
  end

  defp close_connection_safely(connection) do
    case Mint.HTTP.close(connection) do
      {:ok, _closed_connection} -> :ok
      {:error, _connection, _reason} -> :ok
    end
  end
end
