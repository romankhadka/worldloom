defmodule Worldloom.TestSupport.WebSocketFixtureServer.Router do
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(options), do: options

  @impl true
  def call(%Plug.Conn{request_path: "/socket"} = connection, options) do
    connection
    |> WebSockAdapter.upgrade(
      Worldloom.TestSupport.WebSocketFixtureServer.Socket,
      %{test_process: Keyword.fetch!(options, :test_process)},
      timeout: 10_000
    )
    |> halt()
  end

  def call(connection, _options), do: send_resp(connection, 404, "not found")
end
