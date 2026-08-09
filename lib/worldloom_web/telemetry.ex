defmodule WorldloomWeb.Telemetry do
  use Supervisor

  import Telemetry.Metrics

  require Logger

  alias Worldloom.Loom.Event
  alias Worldloom.Loom.Coordinator
  alias Worldloom.Repo
  alias WorldloomWeb.Presence

  @feed_sources [:wikimedia, :usgs, :open_meteo]
  @feed_statuses [:success, :failure]
  @retry_operations [:connection, :persistence]

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(options) do
    children =
      if Keyword.get(options, :periodic_measurements, true) do
        [
          # Telemetry poller will execute the given period measurements
          # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
          {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
          # Add reporters as children of your supervision tree.
          # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("worldloom.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("worldloom.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("worldloom.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("worldloom.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("worldloom.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Worldloom Metrics
      sum("worldloom.loom.commit.count", tags: [:kind, :status]),
      summary("worldloom.loom.commit.duration",
        tags: [:kind, :status],
        unit: {:native, :millisecond}
      ),
      sum("worldloom.loom.coordinator.start.count"),
      sum("worldloom.signals.feed.count", tags: [:source, :status]),
      summary("worldloom.signals.feed.duration",
        tags: [:source, :status],
        unit: {:native, :millisecond}
      ),
      sum("worldloom.signals.retry.count", tags: [:source, :operation]),
      last_value("worldloom.signals.buffer.depth"),
      last_value("worldloom.runtime.viewer_count"),
      last_value("worldloom.runtime.live_view_count"),
      last_value("worldloom.runtime.beam_process_count"),
      last_value("worldloom.runtime.coordinator_alive"),
      last_value("worldloom.runtime.coordinator_restart_count"),
      last_value("worldloom.runtime.database_pool_capacity"),
      last_value("worldloom.runtime.database_pool_ready"),
      last_value("worldloom.runtime.database_pool_queue"),
      last_value("worldloom.runtime.database_pool_utilization"),
      last_value("worldloom.runtime.durable_event_count"),
      last_value("worldloom.runtime.durable_event_bytes", unit: :byte),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  @spec record_feed(atom(), atom(), keyword()) :: :ok
  def record_feed(source, status, options)
      when source in @feed_sources and status in @feed_statuses and is_list(options) do
    duration = non_negative_integer!(options, :duration)
    count = non_negative_integer!(options, :count)
    attempt = non_negative_integer!(options, :attempt)

    :telemetry.execute(
      [:worldloom, :signals, :feed],
      %{duration: duration, count: count},
      %{source: source, status: status, attempt: attempt}
    )

    Logger.log(feed_log_level(status), feed_log_message(status),
      source: source,
      status: status,
      attempt: attempt,
      duration: duration,
      count: count
    )
  end

  @spec record_retry(atom(), atom(), keyword()) :: :ok
  def record_retry(source, operation, options)
      when source in @feed_sources and operation in @retry_operations and is_list(options) do
    attempt = non_negative_integer!(options, :attempt)
    delay = non_negative_integer!(options, :delay)

    :telemetry.execute(
      [:worldloom, :signals, :retry],
      %{count: 1, delay: delay},
      %{source: source, operation: operation, attempt: attempt}
    )

    Logger.warning("Worldloom feed retry scheduled",
      source: source,
      status: :retry,
      attempt: attempt,
      duration: delay,
      count: 1
    )
  end

  @spec record_buffer_depth(non_neg_integer()) :: :ok
  def record_buffer_depth(depth) when is_integer(depth) and depth >= 0 do
    :telemetry.execute(
      [:worldloom, :signals, :buffer, :depth],
      %{depth: depth, observed_at: System.monotonic_time(:millisecond)},
      %{}
    )
  end

  @spec measure_runtime(keyword()) :: :ok
  def measure_runtime(options \\ []) do
    viewer_counter = Keyword.get(options, :viewer_counter, &Presence.viewer_count/0)
    durable_storage = Keyword.get(options, :durable_storage, &durable_storage/0)
    viewer_count = safely_measure(viewer_counter, 0)
    {durable_event_count, durable_event_bytes} = safely_measure(durable_storage, {0, 0})

    {database_pool_capacity, database_pool_ready, database_pool_queue, database_pool_utilization} =
      safely_measure(&database_pool_status/0, {0, 0, 0, 0.0})

    :telemetry.execute(
      [:worldloom, :runtime],
      %{
        viewer_count: viewer_count,
        live_view_count: viewer_count,
        beam_process_count: :erlang.system_info(:process_count),
        coordinator_alive: coordinator_alive(),
        coordinator_restart_count: max(Coordinator.start_count() - 1, 0),
        database_pool_capacity: database_pool_capacity,
        database_pool_ready: database_pool_ready,
        database_pool_queue: database_pool_queue,
        database_pool_utilization: database_pool_utilization,
        durable_event_count: durable_event_count,
        durable_event_bytes: durable_event_bytes
      },
      %{}
    )
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_runtime, []}
    ]
  end

  defp durable_storage do
    durable_event_count = Repo.aggregate(Event, :count, :id)

    durable_event_bytes =
      case Repo.query("SELECT pg_total_relation_size('loom_events')", [], timeout: 1_000) do
        {:ok, %{rows: [[bytes]]}} when is_integer(bytes) and bytes >= 0 -> bytes
        _unavailable -> 0
      end

    {durable_event_count, durable_event_bytes}
  end

  defp database_pool_status do
    connection_metrics =
      Repo
      |> Supervisor.which_children()
      |> Enum.flat_map(fn
        {pool_module, pool, :worker, _modules} when is_atom(pool_module) and is_pid(pool) ->
          DBConnection.get_connection_metrics(pool, pool: pool_module)

        _other_child ->
          []
      end)

    pool_metrics =
      Enum.filter(connection_metrics, fn metric -> match?({:pool, _pool}, metric.source) end)

    pool_size = Keyword.get(Repo.config(), :pool_size, 10)
    capacity = pool_size * length(pool_metrics)
    ready = Enum.sum(Enum.map(pool_metrics, & &1.ready_conn_count))
    queue = Enum.sum(Enum.map(connection_metrics, & &1.checkout_queue_length))
    utilization = if capacity == 0, do: 0.0, else: (capacity - ready) / capacity

    {capacity, ready, queue, utilization |> max(0.0) |> min(1.0)}
  end

  defp coordinator_alive do
    if Process.whereis(Worldloom.Loom.Coordinator), do: 1, else: 0
  end

  defp safely_measure(measurement, fallback) do
    measurement.()
  rescue
    _exception -> fallback
  catch
    :exit, _reason -> fallback
  end

  defp non_negative_integer!(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, integer} when is_integer(integer) and integer >= 0 -> integer
      _invalid -> raise ArgumentError, "#{key} must be a non-negative integer"
    end
  end

  defp feed_log_level(:success), do: :debug
  defp feed_log_level(:failure), do: :warning
  defp feed_log_message(:success), do: "Worldloom feed contact succeeded"
  defp feed_log_message(:failure), do: "Worldloom feed unavailable"
end
