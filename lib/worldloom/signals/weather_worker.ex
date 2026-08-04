defmodule Worldloom.Signals.WeatherWorker do
  use GenServer

  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.Client
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
      clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
      timer: Keyword.get(options, :timer, &Process.send_after/3)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    started_at = System.monotonic_time()
    {status, count} = poll(state)

    Telemetry.record_feed(:open_meteo, status,
      duration: System.monotonic_time() - started_at,
      count: count,
      attempt: 0
    )

    state.timer.(self(), :poll, state.interval_ms)
    {:noreply, state}
  end

  defp poll(state) do
    with {:ok, %{status: 200, body: body}} <- state.client.(state.url, params: params()),
         {:ok, event} <- Normalizer.weather(List.wrap(body), @anchors),
         :ok <- state.buffer.([event], checkpoint(state, event)) do
      {:success, 1}
    else
      _failure -> {:failure, 0}
    end
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
