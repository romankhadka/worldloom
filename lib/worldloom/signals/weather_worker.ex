defmodule Worldloom.Signals.WeatherWorker do
  use GenServer

  alias Worldloom.Signals.Backoff
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.Client
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.Normalizer
  alias WorldloomWeb.Telemetry

  @source "open_meteo"
  @current_fields "temperature_2m,precipitation,wind_speed_10m,is_day"
  @anchors [
    %{label: "Vancouver", latitude: 49.2827, longitude: -123.1207},
    %{label: "Mexico City", latitude: 19.4326, longitude: -99.1332},
    %{label: "São Paulo", latitude: -23.5505, longitude: -46.6333},
    %{label: "Reykjavík", latitude: 64.1466, longitude: -21.9426},
    %{label: "London", latitude: 51.5074, longitude: -0.1278},
    %{label: "Lagos", latitude: 6.5244, longitude: 3.3792},
    %{label: "Nairobi", latitude: -1.2921, longitude: 36.8219},
    %{label: "Cape Town", latitude: -33.9249, longitude: 18.4241},
    %{label: "Mumbai", latitude: 19.076, longitude: 72.8777},
    %{label: "Singapore", latitude: 1.3521, longitude: 103.8198},
    %{label: "Tokyo", latitude: 35.6762, longitude: 139.6503},
    %{label: "Sydney", latitude: -33.8688, longitude: 151.2093}
  ]

  @spec anchors() :: [map()]
  def anchors, do: @anchors

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, registration_options(name))
  end

  @impl true
  def init(options) do
    state = %{
      url: Keyword.fetch!(options, :url),
      interval_ms: Keyword.fetch!(options, :interval_ms),
      client: Keyword.get(options, :client, &Client.get_json/2),
      buffer: Keyword.get(options, :buffer, &Buffer.submit/2),
      health_registry: Keyword.get(options, :health_registry, HealthRegistry),
      clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
      random: Keyword.get(options, :random, &:rand.uniform/0),
      timer: Keyword.get(options, :timer, &Process.send_after/3),
      attempt: 0
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    started_at = System.monotonic_time()

    case poll(state) do
      {:ok, updated_state, count} ->
        Telemetry.record_feed(:open_meteo, :success,
          duration: System.monotonic_time() - started_at,
          count: count,
          attempt: state.attempt
        )

        updated_state.timer.(self(), :poll, updated_state.interval_ms)
        {:noreply, %{updated_state | attempt: 0}}

      {:error, failed_state, operation, drop_reason} ->
        Telemetry.record_feed(:open_meteo, :failure,
          duration: System.monotonic_time() - started_at,
          count: 0,
          attempt: state.attempt
        )

        {:noreply, schedule_retry(failed_state, operation, drop_reason)}
    end
  end

  defp poll(state) do
    case state.client.(state.url, params: params()) do
      {:ok, %{status: 200, body: body}} -> submit_event(state, body)
      _failure -> {:error, record_health(state, :disconnected), :connection, :transport}
    end
  end

  defp submit_event(state, body) do
    case Normalizer.weather(List.wrap(body), @anchors) do
      {:ok, event} ->
        connected = record_health(state, :connected)

        case state.buffer.([event], checkpoint(state, event)) do
          :ok -> {:ok, record_health(connected, {:activity, 1}), 1}
          {:error, _reason} -> {:error, connected, :persistence, :persistence}
        end

      {:error, _reason} ->
        {:error, record_health(state, :connected), :connection, :malformed}
    end
  end

  defp schedule_retry(state, operation, drop_reason) do
    delay = Backoff.delay(state.attempt, state.random.())
    attempt = state.attempt + 1

    Telemetry.record_retry(:open_meteo, operation, attempt: attempt, delay: delay)

    state =
      state
      |> record_health({:drop, drop_reason})
      |> record_health({:retry, 1})

    state.timer.(self(), :poll, delay)
    %{state | attempt: attempt}
  end

  defp record_health(state, observation) do
    :ok = HealthRegistry.record(state.health_registry, :open_meteo, observation)
    state
  end

  defp params do
    %{
      latitude: Enum.map_join(@anchors, ",", & &1.latitude),
      longitude: Enum.map_join(@anchors, ",", & &1.longitude),
      current: @current_fields,
      timezone: "UTC"
    }
  end

  defp checkpoint(state, event) do
    %{
      source: @source,
      cursor: nil,
      etag: nil,
      last_successful_at: state.clock.(),
      metadata: %{"observation_at" => DateTime.to_iso8601(event.occurred_at)}
    }
  end

  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
