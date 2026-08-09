defmodule Worldloom.Signals.SafeEndpoint do
  @invalid_label "invalid-endpoint"

  @spec label(term()) :: String.t()
  def label(endpoint) do
    case absolute_uri(endpoint) do
      {:ok, uri} ->
        uri
        |> Map.merge(%{userinfo: nil, query: nil, fragment: nil})
        |> URI.to_string()

      {:error, :invalid_endpoint} ->
        @invalid_label
    end
  end

  @spec parse(term()) :: {:ok, URI.t()} | {:error, :invalid_endpoint}
  def parse(endpoint) do
    with {:ok, uri} <- absolute_uri(endpoint),
         true <- uri.scheme == "wss",
         true <- is_nil(uri.userinfo),
         true <- uri.port in 1..65_535 do
      {:ok, uri}
    else
      _invalid -> {:error, :invalid_endpoint}
    end
  end

  defp absolute_uri(endpoint) when is_binary(endpoint) and endpoint != "" do
    with {:ok, uri} <- URI.new(endpoint),
         true <- is_binary(uri.scheme) and uri.scheme != "",
         true <- is_binary(uri.host) and uri.host != "" do
      {:ok, uri}
    else
      _invalid -> {:error, :invalid_endpoint}
    end
  end

  defp absolute_uri(_endpoint), do: {:error, :invalid_endpoint}
end
