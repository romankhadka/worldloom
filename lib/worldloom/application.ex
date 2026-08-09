defmodule Worldloom.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {WorldloomWeb.Telemetry, configured_options(WorldloomWeb.Telemetry)},
      Worldloom.Repo,
      {DNSCluster, query: Application.get_env(:worldloom, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Worldloom.PubSub},
      WorldloomWeb.Presence,
      Worldloom.Loom.RateLimiter,
      {Worldloom.Loom.Coordinator, configured_options(Worldloom.Loom.Coordinator)},
      Worldloom.Signals.HealthRegistry,
      {Worldloom.Signals.HealthMonitor, enabled: signal_ingestion_enabled?()},
      Worldloom.Signals.Buffer,
      Worldloom.Signals.Supervisor,
      # Start a worker by calling: Worldloom.Worker.start_link(arg)
      # {Worldloom.Worker, arg},
      # Start to serve requests, typically the last entry
      WorldloomWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Worldloom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WorldloomWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp signal_ingestion_enabled? do
    :worldloom
    |> Application.fetch_env!(Worldloom.Signals)
    |> Keyword.get(:enabled, true)
  end

  defp configured_options(module), do: Application.get_env(:worldloom, module, [])
end
