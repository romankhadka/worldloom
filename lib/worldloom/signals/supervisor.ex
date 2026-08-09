defmodule Worldloom.Signals.Supervisor do
  use Supervisor

  alias Worldloom.Signals.Config
  alias Worldloom.Signals.BlueskySocket
  alias Worldloom.Signals.DrandWorker
  alias Worldloom.Signals.EarthquakeWorker
  alias Worldloom.Signals.RipeSocket
  alias Worldloom.Signals.SolanaSocket
  alias Worldloom.Signals.WeatherWorker
  alias Worldloom.Signals.WikimediaWorker

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, options, registration_options(name))
  end

  @impl true
  def init(options) do
    children =
      case Keyword.fetch(options, :children) do
        {:ok, children} -> children
        :error -> configured_children(Keyword.get(options, :config, signal_config()))
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp configured_children(%Config{enabled: false}), do: []

  defp configured_children(%Config{enabled: true} = config) do
    existing_children(config) ++
      Enum.reject(
        [
          optional_child(
            config.drand_enabled,
            {DrandWorker, client_options: [origins: config.drand_relays]}
          ),
          optional_child(config.bluesky_enabled, {BlueskySocket, url: config.bluesky_url}),
          optional_child(
            config.ripe_enabled,
            {RipeSocket, url: config.ripe_url, collectors: config.ripe_collectors}
          ),
          optional_child(config.solana_enabled, {SolanaSocket, url: config.solana_url})
        ],
        &is_nil/1
      )
  end

  defp existing_children(config) do
    [
      {Task.Supervisor, name: Worldloom.Signals.StreamSupervisor},
      {WikimediaWorker,
       url: config.wikimedia_url, task_supervisor: Worldloom.Signals.StreamSupervisor},
      {EarthquakeWorker, url: config.usgs_url, interval_ms: config.earthquake_interval_ms},
      {WeatherWorker, url: config.open_meteo_url, interval_ms: config.weather_interval_ms}
    ]
  end

  defp optional_child(true, child), do: child
  defp optional_child(false, _child), do: nil
  defp signal_config, do: Application.fetch_env!(:worldloom, Worldloom.Signals)
  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
