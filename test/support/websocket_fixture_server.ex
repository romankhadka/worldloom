defmodule Worldloom.TestSupport.WebSocketFixtureServer do
  @certificate "test/support/fixtures/tls/localhost_certificate.pem"
  @private_key "test/support/fixtures/tls/localhost_key.pem"

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    test_process = Keyword.fetch!(options, :test_process)

    Bandit.start_link(
      plug: {Worldloom.TestSupport.WebSocketFixtureServer.Router, test_process: test_process},
      scheme: :https,
      ip: {127, 0, 0, 1},
      port: 0,
      certfile: Path.expand(@certificate),
      keyfile: Path.expand(@private_key),
      startup_log: false,
      http_2_options: [enabled: false],
      thousand_island_options: [num_acceptors: 1, silent_terminate_on_error: true],
      websocket_options: [compress: false, max_frame_size: 300_000]
    )
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: {__MODULE__, System.unique_integer([:positive])},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  @spec endpoint(pid(), String.t()) :: String.t()
  def endpoint(server, host \\ "localhost") do
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "wss://#{host}:#{port}/socket"
  end
end
