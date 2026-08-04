defmodule Worldloom.Signals.HealthMonitor do
  use GenServer

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Repo
  alias Worldloom.Signals.FeedHealth

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

    state = %{
      enabled: Keyword.get(options, :enabled, true),
      health: FeedHealth.project([], clock.()),
      broadcasted?: false,
      loader: Keyword.get(options, :loader, &load_checkpoints/0),
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
    health = state.loader.() |> FeedHealth.project(state.clock.())

    :telemetry.execute(
      [:worldloom, :signals, :health],
      %{observed_at: System.system_time(:millisecond)},
      %{health: health}
    )

    broadcasted? = maybe_broadcast(state, health)
    state.timer.(self(), :refresh, @refresh_interval)

    {:noreply, %{state | health: health, broadcasted?: broadcasted?}}
  end

  defp maybe_broadcast(%{broadcasted?: true, health: health}, health), do: true

  defp maybe_broadcast(state, health) do
    state.broadcaster.(health)
    true
  end

  defp load_checkpoints, do: Repo.all(FeedCheckpoint)

  defp broadcast(health) do
    Phoenix.PubSub.broadcast(Worldloom.PubSub, @topic, {:feed_health, health})
  end

  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
