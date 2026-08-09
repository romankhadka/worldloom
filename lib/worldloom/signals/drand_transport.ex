defmodule Worldloom.Signals.DrandTransport do
  @moduledoc false

  @allowed_hosts ~w(api.drand.sh api2.drand.sh api3.drand.sh)
  @body_limit 4_096
  @header_limit 16_384

  @spec get(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, :unavailable}
  def get(url, options), do: get(url, options, Mint.HTTP)

  @doc false
  @spec get(String.t(), keyword(), module()) ::
          {:ok, Req.Response.t()} | {:error, :unavailable}
  def get(url, options, mint) when is_binary(url) and is_list(options) and is_atom(mint) do
    with {:ok, endpoint} <- endpoint(url),
         {:ok, request_options} <- request_options(options),
         {:ok, connection} <-
           mint.connect(
             :https,
             endpoint.host,
             endpoint.port,
             connect_options(request_options)
           ) do
      request_over_connection(mint, connection, endpoint.path, request_options)
    else
      _unavailable -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def get(_url, _options, _mint), do: {:error, :unavailable}

  defp endpoint(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        port: port,
        path: path,
        query: nil,
        fragment: nil,
        userinfo: nil
      }
      when host in @allowed_hosts and port in [nil, 443] and is_binary(path) and path != "" ->
        {:ok, %{host: host, port: port || 443, path: path}}

      _invalid ->
        {:error, :unavailable}
    end
  end

  defp request_options(options) do
    with headers when is_list(headers) <- Keyword.get(options, :headers),
         connect_options when is_list(connect_options) <- Keyword.get(options, :connect_options),
         connect_timeout when is_integer(connect_timeout) and connect_timeout > 0 <-
           Keyword.get(connect_options, :timeout),
         transport_options when is_list(transport_options) <-
           Keyword.get(connect_options, :transport_opts),
         send_timeout when is_integer(send_timeout) and send_timeout > 0 <-
           Keyword.get(transport_options, :send_timeout),
         receive_timeout when is_integer(receive_timeout) and receive_timeout > 0 <-
           Keyword.get(options, :receive_timeout),
         true <- valid_headers?(headers) do
      {:ok,
       %{
         headers: headers,
         connect_timeout: connect_timeout,
         send_timeout: send_timeout,
         receive_timeout: receive_timeout
       }}
    else
      _invalid -> {:error, :unavailable}
    end
  end

  defp valid_headers?(headers) do
    Enum.all?(headers, fn
      {name, value} when is_binary(name) and is_binary(value) -> true
      _invalid -> false
    end)
  end

  defp connect_options(options) do
    [
      mode: :passive,
      protocols: [:http1],
      log: false,
      max_header_list_size: @header_limit,
      transport_opts: [timeout: options.connect_timeout, send_timeout: options.send_timeout]
    ]
  end

  defp request_over_connection(mint, connection, path, options) do
    try do
      case mint.request(connection, "GET", path, options.headers, nil) do
        {:ok, updated_connection, request_reference} ->
          receive_response(
            mint,
            updated_connection,
            request_reference,
            options.receive_timeout
          )

        {:error, updated_connection, _reason} ->
          close(mint, updated_connection)
          {:error, :unavailable}

        _invalid ->
          close(mint, connection)
          {:error, :unavailable}
      end
    rescue
      _error ->
        close(mint, connection)
        {:error, :unavailable}
    catch
      _kind, _reason ->
        close(mint, connection)
        {:error, :unavailable}
    end
  end

  defp receive_response(mint, connection, request_reference, receive_timeout) do
    deadline = System.monotonic_time(:millisecond) + receive_timeout

    response_state = %{
      status: nil,
      headers: nil,
      body: "",
      completed: false,
      invalid: false
    }

    {outcome, final_connection} =
      receive_chunks(mint, connection, request_reference, deadline, response_state)

    close(mint, final_connection)
    outcome
  end

  defp receive_chunks(mint, connection, request_reference, deadline, response_state) do
    remaining_timeout = deadline - System.monotonic_time(:millisecond)

    if remaining_timeout <= 0 do
      {{:error, :unavailable}, connection}
    else
      case mint.recv(connection, 0, remaining_timeout) do
        {:ok, updated_connection, responses} ->
          continue_or_finish(
            mint,
            updated_connection,
            request_reference,
            deadline,
            response_state,
            responses
          )

        {:error, updated_connection, _reason, responses} ->
          case consume(responses, request_reference, response_state) do
            {:ok, completed_state} -> completed_response(completed_state, updated_connection)
            _incomplete_or_invalid -> {{:error, :unavailable}, updated_connection}
          end

        _invalid ->
          {{:error, :unavailable}, connection}
      end
    end
  end

  defp continue_or_finish(
         mint,
         connection,
         request_reference,
         deadline,
         response_state,
         responses
       ) do
    case consume(responses, request_reference, response_state) do
      {:ok, completed_state} ->
        completed_response(completed_state, connection)

      {:cont, next_state} ->
        receive_chunks(mint, connection, request_reference, deadline, next_state)

      {:error, :unavailable} ->
        {{:error, :unavailable}, connection}
    end
  end

  defp consume(responses, request_reference, response_state) when is_list(responses) do
    Enum.reduce_while(responses, {:cont, response_state}, fn response, {:cont, state} ->
      case consume_one(response, request_reference, state) do
        {:cont, next_state} -> {:cont, {:cont, next_state}}
        {:ok, completed_state} -> {:halt, {:ok, completed_state}}
        {:error, :unavailable} = error -> {:halt, error}
      end
    end)
  end

  defp consume(_responses, _request_reference, _response_state), do: {:error, :unavailable}

  defp consume_one(
         {:status, request_reference, status},
         request_reference,
         %{status: nil} = state
       )
       when is_integer(status),
       do: {:cont, %{state | status: status}}

  defp consume_one(
         {:headers, request_reference, headers},
         request_reference,
         %{status: status, headers: nil} = state
       )
       when is_integer(status) and is_list(headers),
       do: {:cont, %{state | headers: headers}}

  defp consume_one(
         {:data, request_reference, chunk},
         request_reference,
         %{status: status, headers: headers, body: body} = state
       )
       when is_integer(status) and is_list(headers) and is_binary(chunk) do
    if byte_size(chunk) <= @body_limit - byte_size(body) do
      {:cont, %{state | body: body <> chunk}}
    else
      {:error, :unavailable}
    end
  end

  defp consume_one(
         {:done, request_reference},
         request_reference,
         %{status: status, headers: headers} = state
       )
       when is_integer(status) and is_list(headers),
       do: {:ok, %{state | completed: true}}

  defp consume_one(_response, _request_reference, _state), do: {:error, :unavailable}

  defp completed_response(
         %{completed: true, status: status, headers: headers, body: body},
         connection
       ) do
    response = Req.Response.new(status: status, headers: headers, body: body)
    {{:ok, response}, connection}
  end

  defp close(mint, connection) do
    mint.close(connection)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
