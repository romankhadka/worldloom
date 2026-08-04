defmodule Worldloom.Signals.EarthquakeWorker do
  use GenServer

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Repo
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.Client
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
      clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
      timer: Keyword.get(options, :timer, &Process.send_after/3)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    started_at = System.monotonic_time()
    {updated_state, status, count} = poll(state)

    Telemetry.record_feed(:usgs, status,
      duration: System.monotonic_time() - started_at,
      count: count,
      attempt: 0
    )

    updated_state.timer.(self(), :poll, updated_state.interval_ms)
    {:noreply, updated_state}
  end

  defp poll(state) do
    case state.client.(state.url, etag: state.etag) do
      {:ok, %{status: 200, body: body} = response} ->
        submit_events(state, body, response.etag)

      {:ok, %{status: 304} = response} ->
        submit_contact(state, response.etag || state.etag)

      _failure ->
        {state, :failure, 0}
    end
  end

  defp submit_events(state, body, etag) do
    feed_metadata = metadata(body)

    with {:ok, events} <- Normalizer.earthquakes(body),
         :ok <- state.buffer.(events, checkpoint(state, etag, feed_metadata)) do
      {%{state | etag: etag, metadata: feed_metadata}, :success, length(events)}
    else
      _failure -> {state, :failure, 0}
    end
  end

  defp submit_contact(state, etag) do
    case state.buffer.([], checkpoint(state, etag, state.metadata)) do
      :ok -> {%{state | etag: etag}, :success, 0}
      _failure -> {state, :failure, 0}
    end
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
