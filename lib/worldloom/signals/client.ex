defmodule Worldloom.Signals.Client do
  alias Worldloom.Signals.SSEParser

  @user_agent "Worldloom/1.0 (+https://github.com/romankhadka/worldloom)"
  @connect_timeout 5_000
  @receive_timeout 15_000

  @type response :: %{status: pos_integer(), body: term(), etag: String.t() | nil}

  @spec get_json(Req.Request.t() | URI.t() | String.t(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def get_json(request_or_url, options \\ []) do
    {etag, options} = Keyword.pop(options, :etag)
    {connect_timeout, options} = Keyword.pop(options, :connect_timeout, @connect_timeout)
    {receive_timeout, request_options} = Keyword.pop(options, :receive_timeout, @receive_timeout)

    headers =
      [{"user-agent", @user_agent}, {"accept", "application/json"}]
      |> maybe_add_header("if-none-match", etag)

    request_options =
      Keyword.merge(request_options,
        headers: headers,
        connect_options: [timeout: connect_timeout],
        receive_timeout: receive_timeout,
        retry: false
      )

    case Req.get(request_or_url, request_options) do
      {:ok, %Req.Response{status: status} = response} when status in [200, 304] ->
        {:ok,
         %{
           status: status,
           body: response.body,
           etag: response |> Req.Response.get_header("etag") |> List.first()
         }}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        normalize_error(reason)
    end
  end

  @spec stream_sse(
          Req.Request.t() | URI.t() | String.t(),
          String.t() | nil,
          (SSEParser.frame() -> term())
        ) :: {:error, term()}
  def stream_sse(request_or_url, last_event_id, frame_callback)
      when (is_binary(last_event_id) or is_nil(last_event_id)) and
             is_function(frame_callback, 1) do
    headers =
      [{"user-agent", @user_agent}, {"accept", "text/event-stream"}]
      |> maybe_add_header("last-event-id", last_event_id)

    into = fn {:data, chunk}, {request, response} ->
      buffer = Req.Response.get_private(response, :worldloom_sse_buffer, "")
      {frames, remaining_buffer} = SSEParser.push(buffer, chunk)
      Enum.each(frames, frame_callback)
      response = Req.Response.put_private(response, :worldloom_sse_buffer, remaining_buffer)
      {:cont, {request, response}}
    end

    request_options = [
      headers: headers,
      connect_options: [timeout: @connect_timeout],
      receive_timeout: @receive_timeout,
      retry: false,
      decode_body: false,
      into: into
    ]

    case Req.get(request_or_url, request_options) do
      {:ok, %Req.Response{status: 200}} -> {:error, :disconnected}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> normalize_error(reason)
    end
  rescue
    error in ArgumentError -> {:error, {:invalid_stream, Exception.message(error)}}
  end

  def stream_sse(_request_or_url, _last_event_id, _frame_callback),
    do: {:error, {:invalid_stream, "invalid stream arguments"}}

  defp maybe_add_header(headers, _name, nil), do: headers
  defp maybe_add_header(headers, name, value), do: [{name, value} | headers]

  defp normalize_error(%Req.TransportError{reason: reason}), do: {:error, {:transport, reason}}
  defp normalize_error(%Jason.DecodeError{} = reason), do: {:error, {:decode, reason}}
  defp normalize_error(reason), do: {:error, {:request, reason}}
end
