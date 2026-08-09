defmodule Worldloom.Signals.HealthMonitor do
  use GenServer

  alias Worldloom.Signals.FeedHealth
  alias Worldloom.Signals.HealthRegistry

  @observed_sources [:wikimedia, :bluesky, :ripe_ris, :solana, :drand, :usgs, :open_meteo]
  @refresh_interval 15_000
  @topic "signals:health"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, registration_options(name))
  end

  @spec current(GenServer.server()) :: FeedHealth.projection()
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @spec topic() :: String.t()
  def topic, do: @topic

  @impl true
  def init(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)
    registry = Keyword.get(options, :registry, HealthRegistry)

    observation_loader =
      Keyword.get(options, :observation_loader, fn -> HealthRegistry.current(registry) end)

    state = %{
      enabled: Keyword.get(options, :enabled, true),
      health: initial_health(observation_loader, clock),
      broadcasted?: false,
      observation_loader: observation_loader,
      broadcaster: Keyword.get(options, :broadcaster, &broadcast/1),
      clock: clock,
      timer: Keyword.get(options, :timer, &Process.send_after/3)
    }

    if state.enabled, do: send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.health, state}

  @impl true
  def handle_info(:refresh, state) do
    updated_state = refresh(state)
    state.timer.(self(), :refresh, @refresh_interval)
    {:noreply, updated_state}
  end

  def handle_info(:health_registry_changed, state), do: {:noreply, refresh(state)}

  defp refresh(state) do
    health =
      FeedHealth.project(
        %{
          observations: state.observation_loader.() |> public_observations()
        },
        state.clock.()
      )

    :telemetry.execute(
      [:worldloom, :signals, :health],
      %{observed_at: System.system_time(:millisecond)},
      %{health: health}
    )

    broadcasted? = maybe_broadcast(state, health)
    %{state | health: health, broadcasted?: broadcasted?}
  end

  defp initial_health(observation_loader, clock) do
    FeedHealth.project(
      %{observations: observation_loader.() |> public_observations()},
      clock.()
    )
  end

  defp public_observations(observations) when is_map(observations) do
    Map.new(@observed_sources, fn source ->
      observation = Map.get(observations, source, %{})

      {source,
       %{
         connection: field(observation, :connection),
         last_contact_at: field(observation, :last_contact_at),
         last_activity_at: field(observation, :last_activity_at)
       }}
    end)
  end

  defp public_observations(_observations), do: %{}

  defp maybe_broadcast(%{broadcasted?: true, health: health}, health), do: true

  defp maybe_broadcast(state, health) do
    state.broadcaster.(health)
    true
  end

  defp broadcast(health) do
    Phoenix.PubSub.broadcast(Worldloom.PubSub, @topic, {:feed_health, health})
  end

  defp field(container, key) when is_map(container), do: Map.get(container, key)
  defp field(_container, _key), do: nil

  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
