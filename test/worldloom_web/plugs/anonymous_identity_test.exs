defmodule WorldloomWeb.Plugs.AnonymousIdentityTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias WorldloomWeb.Endpoint
  alias WorldloomWeb.Plugs.AnonymousIdentity
  alias WorldloomWeb.SessionOptions

  @secret_key_base String.duplicate("secret", 12)

  test "creates a 32-byte URL-safe identity and reuses it through the signed session cookie" do
    first_conn = request() |> AnonymousIdentity.call([]) |> send_resp(200, "public page")
    identity = get_session(first_conn, :visitor_identity)

    assert {:ok, decoded_identity} = Base.url_decode64(identity, padding: false)
    assert byte_size(decoded_identity) == 32
    assert first_conn.assigns.visitor_identity == identity
    refute first_conn.resp_body =~ identity

    session_cookie = first_conn |> get_resp_cookies() |> Map.fetch!("_worldloom_key")
    assert session_cookie.http_only
    assert session_cookie.same_site == "Lax"
    refute session_cookie.secure

    second_conn =
      session_cookie.value
      |> request()
      |> AnonymousIdentity.call([])
      |> send_resp(200, "public page")

    assert get_session(second_conn, :visitor_identity) == identity
    assert second_conn.assigns.visitor_identity == identity
  end

  test "endpoint session options explicitly protect the cookie" do
    options = Endpoint.session_options()

    assert options[:http_only] == true
    assert options[:same_site] == "Lax"
    assert options[:secure] == false
    assert SessionOptions.build(false)[:secure] == false
    assert SessionOptions.build(true)[:secure] == true
  end

  defp request(cookie_value \\ nil) do
    conn =
      :get
      |> conn("/")
      |> Map.put(:secret_key_base, @secret_key_base)
      |> maybe_put_cookie(cookie_value)

    conn
    |> Plug.Session.call(Plug.Session.init(Endpoint.session_options()))
    |> fetch_session()
  end

  defp maybe_put_cookie(conn, nil), do: conn

  defp maybe_put_cookie(conn, cookie_value) do
    put_req_header(conn, "cookie", "_worldloom_key=#{cookie_value}")
  end
end
