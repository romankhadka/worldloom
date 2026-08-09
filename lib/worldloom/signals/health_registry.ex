defmodule Worldloom.Signals.HealthRegistry do
  use GenServer

  alias Worldloom.Signals.BoundedCounter
  alias Worldloom.Signals.HealthMonitor

  @sources [:wikimedia, :bluesky, :ripe_ris, :solana, :drand, :usgs, :open_meteo]
  @drop_reasons [
    :oversized,
    :malformed,
    :capacity,
    :mailbox,
    :heap,
    :backpressure,
    :transport,
    :timeout,
    :subscription,
    :stale,
    :duplicate,
    :replay,
    :persistence,
    :unsupported,
    :binary
  ]
  @uint32_max 4_294_967_295

  @type source :: :wikimedia | :bluesky | :ripe_ris | :solana | :drand | :usgs | :open_meteo
  @type drop_reason ::
          :oversized
          | :malformed
          | :capacity
          | :mailbox
          | :heap
          | :backpressure
          | :transport
          | :timeout
          | :subscription
          | :stale
          | :duplicate
          | :replay
          | :persistence
          | :unsupported
          | :binary
  @type observation ::
          :connected
          | :contact
          | :disconnected
          | {:activity, pos_integer()}
          | {:drop, drop_reason()}
          | {:merge, pos_integer()}
          | {:recovery, pos_integer()}
          | {:retry, pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, registration_options(name))
  end

  @spec record(source(), observation()) :: :ok | {:error, :invalid_observation}
  def record(source, observation), do: record(__MODULE__, source, observation)

  @spec record(GenServer.server(), source(), observation()) ::
          :ok | {:error, :invalid_observation}
  def record(server, source, observation) do
    GenServer.call(server, {:record, source, observation})
  end

  @spec current(GenServer.server()) :: map()
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @impl true
  def init(options) do
    state = %{
      clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
      monitor: Keyword.get(options, :monitor, HealthMonitor),
      observations: Map.new(@sources, &{&1, empty_observation()})
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.observations, state}

  def handle_call({:record, source, observation}, _from, state) do
    with true <- source in @sources,
         {:ok, operation} <- operation(observation),
         %DateTime{} = observed_at <- state.clock.() do
      current = Map.fetch!(state.observations, source)
      updated = update_observation(current, operation, observed_at)

      if updated.connection != current.connection do
        notify_monitor(state.monitor)
      end

      observations = Map.put(state.observations, source, updated)
      {:reply, :ok, %{state | observations: observations}}
    else
      _invalid -> {:reply, {:error, :invalid_observation}, state}
    end
  end

  defp operation(:connected), do: {:ok, :connected}
  defp operation(:contact), do: {:ok, :contact}
  defp operation(:disconnected), do: {:ok, :disconnected}

  defp operation({:activity, count}) when count in 1..@uint32_max,
    do: {:ok, :activity}

  defp operation({:drop, reason}) when reason in @drop_reasons,
    do: {:ok, {:drop, reason}}

  defp operation({operation, count})
       when operation in [:merge, :recovery, :retry] and count in 1..@uint32_max,
       do: {:ok, {operation, count}}

  defp operation(_invalid), do: {:error, :invalid_observation}

  defp update_observation(observation, :connected, _observed_at),
    do: %{observation | connection: :connected}

  defp update_observation(observation, :contact, observed_at),
    do: %{observation | last_contact_at: observed_at}

  defp update_observation(observation, :activity, observed_at),
    do: %{observation | last_contact_at: observed_at, last_activity_at: observed_at}

  defp update_observation(observation, :disconnected, _observed_at),
    do: %{observation | connection: :disconnected}

  defp update_observation(observation, {:drop, reason}, _observed_at) do
    %{observation | drops: add(observation.drops, 1), last_reason: reason}
  end

  defp update_observation(observation, {:merge, count}, _observed_at),
    do: %{observation | merges: add(observation.merges, count)}

  defp update_observation(observation, {:recovery, count}, _observed_at),
    do: %{observation | recovered_windows: add(observation.recovered_windows, count)}

  defp update_observation(observation, {:retry, count}, _observed_at),
    do: %{observation | retries: add(observation.retries, count)}

  defp add(counter, increment) do
    {updated, _saturated?} = BoundedCounter.add(counter, increment)
    updated
  end

  defp empty_observation do
    %{
      connection: :disconnected,
      last_contact_at: nil,
      last_activity_at: nil,
      drops: 0,
      merges: 0,
      recovered_windows: 0,
      retries: 0,
      last_reason: nil
    }
  end

  defp notify_monitor(monitor) when is_pid(monitor) do
    send(monitor, :health_registry_changed)
    :ok
  end

  defp notify_monitor(monitor) when is_atom(monitor) do
    case Process.whereis(monitor) do
      nil -> :ok
      process -> notify_monitor(process)
    end
  end

  defp notify_monitor(_monitor), do: :ok

  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
