defmodule Mix.Tasks.Worldloom.Providers.Smoke do
  use Mix.Task

  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Signals.BlueskySocket
  alias Worldloom.Signals.Config
  alias Worldloom.Signals.DrandClient
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.RipeSocket

  @requirements ["app.config"]
  @shortdoc "Checks the bounded contracts of Worldloom's public providers"
  @sources [:drand, :bluesky, :ripe]
  @timeout 15_000

  @type failure_reason :: :internal | :protocol | :timeout | :transport
  @type outcome :: :ok | {:error, failure_reason()}

  @impl Mix.Task
  def run(_arguments) do
    outcomes = check(Application.get_env(:worldloom, __MODULE__, []))
    Enum.each(outcomes, &print_outcome/1)

    if Enum.any?(outcomes, fn {_source, outcome} -> outcome != :ok end) do
      Mix.raise("provider contract smoke check failed")
    end

    outcomes
  end

  @doc false
  @spec check(keyword()) :: [{atom(), outcome()}]
  def check(options \\ []) do
    configuration = Keyword.validate!(options, probes: default_probes(), timeout: @timeout)
    probes = validate_probes!(configuration[:probes])
    timeout = validate_timeout!(configuration[:timeout])

    stream_outcomes =
      Task.async_stream(probes, fn {source, probe} -> {source, safely_probe(probe)} end,
        ordered: true,
        max_concurrency: length(@sources),
        timeout: timeout,
        on_timeout: :kill_task
      )

    @sources
    |> Enum.zip(stream_outcomes)
    |> Enum.map(&normalize_task_outcome/1)
  end

  defp default_probes do
    [
      drand: &probe_drand/0,
      bluesky: &probe_bluesky/0,
      ripe: &probe_ripe/0
    ]
  end

  defp validate_probes!(probes) when is_list(probes) do
    if Keyword.keyword?(probes) do
      sources = Keyword.keys(probes)

      if Enum.sort(sources) == Enum.sort(@sources) and
           length(Enum.uniq(sources)) == length(@sources) and
           Enum.all?(probes, fn {_source, probe} -> is_function(probe, 0) end) do
        probe_map = Map.new(probes)
        Enum.map(@sources, &{&1, Map.fetch!(probe_map, &1)})
      else
        invalid_probes!()
      end
    else
      invalid_probes!()
    end
  end

  defp validate_probes!(_probes), do: invalid_probes!()

  defp invalid_probes! do
    raise ArgumentError, "provider probes must define drand, bluesky, and ripe once"
  end

  defp validate_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp validate_timeout!(_timeout), do: raise(ArgumentError, "provider timeout must be positive")

  defp safely_probe(probe) do
    probe.()
    |> normalize_probe_outcome()
  rescue
    _error -> {:error, :internal}
  catch
    _kind, _reason -> {:error, :internal}
  end

  defp normalize_probe_outcome(:ok), do: :ok

  defp normalize_probe_outcome({:error, reason})
       when reason in [:internal, :protocol, :timeout, :transport],
       do: {:error, reason}

  defp normalize_probe_outcome({:error, :unavailable}), do: {:error, :transport}
  defp normalize_probe_outcome({:error, _private_reason}), do: {:error, :protocol}
  defp normalize_probe_outcome(_unexpected), do: {:error, :protocol}

  defp normalize_task_outcome({source, {:ok, {source, outcome}}}), do: {source, outcome}
  defp normalize_task_outcome({source, {:exit, :timeout}}), do: {source, {:error, :timeout}}
  defp normalize_task_outcome({source, _unexpected}), do: {source, {:error, :internal}}

  defp print_outcome({source, :ok}), do: Mix.shell().info("#{source} ok")

  defp print_outcome({source, {:error, reason}}),
    do: Mix.shell().info("#{source} failed #{reason}")

  defp probe_drand do
    with :ok <- ensure_network_applications(),
         {:ok, client} <- DrandClient.new(origins: signal_config().drand_relays),
         {:ok, round} <- current_round(DrandClient.schedule(client)),
         {:ok, %{round: ^round, render_identity: render_identity}}
         when is_binary(render_identity) <- DrandClient.fetch_round(client, round) do
      :ok
    else
      {:error, :unavailable} -> {:error, :transport}
      _invalid -> {:error, :protocol}
    end
  end

  defp probe_bluesky do
    config = signal_config()

    probe_socket(BlueskySocket, :bluesky,
      url: config.bluesky_url,
      committed_cursor: nil
    )
  end

  defp probe_ripe do
    config = signal_config()

    probe_socket(RipeSocket, :ripe_ris,
      url: config.ripe_url,
      collectors: config.ripe_collectors
    )
  end

  defp probe_socket(socket_module, expected_source, options) do
    with :ok <- ensure_network_applications(),
         {:ok, health} <- HealthRegistry.start_link(name: nil, monitor: nil) do
      marker = make_ref()
      observer = self()

      buffer = fn
        [%SourceEvent{source: ^expected_source}], checkpoint when is_map(checkpoint) ->
          :ok

        [], checkpoint when is_map(checkpoint) ->
          :ok

        _events, _checkpoint ->
          {:error, :invalid_observation}
      end

      socket_options =
        Keyword.merge(options,
          name: nil,
          buffer: buffer,
          health_registry: health,
          observation_listener: {observer, marker}
        )

      case socket_module.start_link(socket_options) do
        {:ok, socket} ->
          await_socket_observation(socket, health, marker)

        {:error, _reason} ->
          stop_process(health)
          {:error, :transport}
      end
    else
      _unavailable -> {:error, :transport}
    end
  end

  defp await_socket_observation(socket, health, marker) do
    try do
      receive do
        {:worldloom_provider_observation, ^marker} -> :ok
      end
    after
      stop_process(socket)
      stop_process(health)
    end
  end

  defp current_round(%{period: 3, genesis_time: genesis_time})
       when is_integer(genesis_time) and genesis_time > 0 do
    current_second = System.system_time(:second)

    if current_second >= genesis_time do
      {:ok, div(current_second - genesis_time, 3) + 1}
    else
      {:error, :protocol}
    end
  end

  defp current_round(_invalid), do: {:error, :protocol}

  defp signal_config do
    case Application.fetch_env!(:worldloom, Worldloom.Signals) do
      %Config{} = config -> config
      config when is_list(config) -> Config.from_keyword!(config, Mix.env())
    end
  end

  defp ensure_network_applications do
    with {:ok, _started} <- Application.ensure_all_started(:req),
         {:ok, _started} <- Application.ensure_all_started(:mint_web_socket) do
      :ok
    else
      _unavailable -> {:error, :transport}
    end
  end

  defp stop_process(process) when is_pid(process) do
    if Process.alive?(process), do: GenServer.stop(process, :normal, 1_000), else: :ok
  catch
    :exit, _reason -> :ok
  end
end
