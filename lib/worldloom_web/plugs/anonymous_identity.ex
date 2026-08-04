defmodule WorldloomWeb.Plugs.AnonymousIdentity do
  import Plug.Conn

  @session_key :visitor_identity
  @identity_bytes 32

  @spec init(keyword()) :: keyword()
  def init(options), do: options

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _options) do
    identity =
      case get_session(conn, @session_key) do
        existing_identity when is_binary(existing_identity) ->
          if valid_identity?(existing_identity), do: existing_identity, else: new_identity()

        _missing_identity ->
          new_identity()
      end

    conn
    |> put_session(@session_key, identity)
    |> assign(:visitor_identity, identity)
  end

  defp valid_identity?(identity) do
    case Base.url_decode64(identity, padding: false) do
      {:ok, decoded_identity} -> byte_size(decoded_identity) == @identity_bytes
      :error -> false
    end
  end

  defp new_identity do
    @identity_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
