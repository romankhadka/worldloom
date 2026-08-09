defmodule Worldloom.Signals.EarthquakeWorker do
  use GenServer

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Repo
  alias Worldloom.Signals.Backoff
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.Client
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.Normalizer
  alias WorldloomWeb.Telemetry

  @source "usgs"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, registration_options(name))
  end

  @impl true
  def init(options) do
    checkpoint = Repo.get(FeedCheckpoint, @source)

    state = %{
      url: Keyword.fetch!(options, :url),
      interval_ms: Keyword.fetch!(options, :interval_ms),
      etag: checkpoint && checkpoint.etag,
      metadata: (checkpoint && checkpoint.metadata) || %{},
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
        Telemetry.record_feed(:usgs, :success,
          duration: System.monotonic_time() - started_at,
          count: count,
          attempt: state.attempt
        )

        updated_state.timer.(self(), :poll, updated_state.interval_ms)
        {:noreply, %{updated_state | attempt: 0}}

      {:error, failed_state, operation, drop_reason} ->
        Telemetry.record_feed(:usgs, :failure,
          duration: System.monotonic_time() - started_at,
          count: 0,
          attempt: state.attempt
        )

        {:noreply, schedule_retry(failed_state, operation, drop_reason)}
    end
  end

  defp poll(state) do
    case state.client.(state.url, etag: state.etag) do
      {:ok, %{status: 200, body: body} = response} ->
        submit_events(state, body, response.etag)

      {:ok, %{status: 304} = response} ->
        submit_contact(state, response.etag || state.etag)

      _failure ->
        {:error, record_health(state, :disconnected), :connection, :transport}
    end
  end

  defp submit_events(state, body, etag) do
    feed_metadata = metadata(body)

    case Normalizer.earthquakes(body) do
      {:ok, events} ->
        connected = record_health(state, :connected)

        case state.buffer.(events, checkpoint(state, etag, feed_metadata)) do
          :ok ->
            active =
              if events == [],
                do: record_health(connected, :contact),
                else: record_health(connected, {:activity, length(events)})

            {:ok, %{active | etag: etag, metadata: feed_metadata}, length(events)}

          {:error, _reason} ->
            {:error, connected, :persistence, :persistence}
        end

      {:error, _reason} ->
        {:error, record_health(state, :connected), :connection, :malformed}
    end
  end

  defp submit_contact(state, etag) do
    connected = record_health(state, :connected)

    case state.buffer.([], checkpoint(state, etag, state.metadata)) do
      :ok -> {:ok, %{record_health(connected, :contact) | etag: etag}, 0}
      {:error, _reason} -> {:error, connected, :persistence, :persistence}
    end
  end

  defp schedule_retry(state, operation, drop_reason) do
    delay = Backoff.delay(state.attempt, state.random.())
    attempt = state.attempt + 1

    Telemetry.record_retry(:usgs, operation, attempt: attempt, delay: delay)

    state =
      state
      |> record_health({:drop, drop_reason})
      |> record_health({:retry, 1})

    state.timer.(self(), :poll, delay)
    %{state | attempt: attempt}
  end

  defp record_health(state, observation) do
    :ok = HealthRegistry.record(state.health_registry, :usgs, observation)
    state
  end

  defp checkpoint(state, etag, metadata) do
    %{
      source: @source,
      cursor: nil,
      etag: etag,
      last_successful_at: state.clock.(),
      metadata: metadata
    }
  end

  defp metadata(%{"metadata" => %{"generated" => generated_at}}),
    do: %{"generated_at" => generated_at}

  defp metadata(_body), do: %{}

  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
