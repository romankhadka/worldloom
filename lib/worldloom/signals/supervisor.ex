defmodule Worldloom.Signals.Supervisor do
  use Supervisor

  alias Worldloom.Signals.Config
  alias Worldloom.Signals.EarthquakeWorker
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

  defp configured_children(config) do
    if configured?(config, :enabled, true) do
      [
        {Task.Supervisor, name: Worldloom.Signals.StreamSupervisor},
        {WikimediaWorker,
         url: fetch_config!(config, :wikimedia_url),
         task_supervisor: Worldloom.Signals.StreamSupervisor},
        {EarthquakeWorker,
         url: fetch_config!(config, :usgs_url),
         interval_ms: fetch_config!(config, :earthquake_interval_ms)},
        {WeatherWorker,
         url: fetch_config!(config, :open_meteo_url),
         interval_ms: fetch_config!(config, :weather_interval_ms)}
      ]
    else
      []
    end
  end

  defp signal_config, do: Application.fetch_env!(:worldloom, Worldloom.Signals)
  defp configured?(%Config{} = config, setting, _default), do: Map.fetch!(config, setting)
  defp configured?(config, setting, default), do: Keyword.get(config, setting, default)
  defp fetch_config!(%Config{} = config, setting), do: Map.fetch!(config, setting)
  defp fetch_config!(config, setting), do: Keyword.fetch!(config, setting)
  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
