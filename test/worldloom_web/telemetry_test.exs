defmodule WorldloomWeb.TelemetryTest do
  use Worldloom.DataCase, async: false

  import ExUnit.CaptureLog

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.CoordinatorTestStore
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store
  alias WorldloomWeb.Telemetry

  @events [
    [:worldloom, :loom, :commit],
    [:worldloom, :loom, :coordinator, :start],
    [:worldloom, :signals, :feed],
    [:worldloom, :signals, :retry],
    [:worldloom, :signals, :buffer, :depth],
    [:worldloom, :runtime]
  ]

  test "ordinary test startup disables only scheduled runtime polling" do
    assert Application.fetch_env!(:worldloom, Telemetry)[:periodic_measurements] == false
    assert Supervisor.which_children(Telemetry) == []
  end

  test "publishes the complete bounded operations contract" do
    handler_id = {__MODULE__, make_ref()}
    test_process = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        fn event_name, measurements, metadata, _handler_config ->
          send(test_process, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    coordinator = start_coordinator()

    assert_receive {:telemetry, [:worldloom, :loom, :coordinator, :start], %{count: 1}, %{}},
                   500

    assert {:ok, [_event]} =
             Coordinator.commit_external(
               coordinator,
               [source_event()],
               checkpoint()
             )

    Telemetry.record_feed(:usgs, :success, duration: 17, count: 3, attempt: 0)
    Telemetry.record_feed(:open_meteo, :failure, duration: 23, count: 0, attempt: 1)
    Telemetry.record_retry(:wikimedia, :connection, attempt: 2, delay: 1_000)
    Telemetry.record_buffer_depth(4)
    Telemetry.measure_runtime()

    assert_receive {:telemetry, [:worldloom, :loom, :commit], commit_measurements,
                    %{kind: :external, status: :ok}},
                   500

    assert commit_measurements.count == 1
    assert commit_measurements.duration >= 0

    assert_receive {:telemetry, [:worldloom, :signals, :feed], %{duration: 17, count: 3},
                    %{source: :usgs, status: :success, attempt: 0}},
                   500

    assert_receive {:telemetry, [:worldloom, :signals, :feed], %{duration: 23, count: 0},
                    %{source: :open_meteo, status: :failure, attempt: 1}},
                   500

    assert_receive {:telemetry, [:worldloom, :signals, :retry], %{count: 1, delay: 1_000},
                    %{source: :wikimedia, operation: :connection, attempt: 2}},
                   500

    assert_receive {:telemetry, [:worldloom, :signals, :buffer, :depth],
                    %{depth: 4, observed_at: observed_at}, %{}},
                   500

    assert is_integer(observed_at)

    assert_receive {:telemetry, [:worldloom, :runtime], runtime_measurements, %{}}, 500
    assert is_integer(runtime_measurements.viewer_count)
    assert is_integer(runtime_measurements.live_view_count)
    assert is_integer(runtime_measurements.beam_process_count)
    assert runtime_measurements.coordinator_alive in [0, 1]
    assert is_integer(runtime_measurements.coordinator_restart_count)
    assert is_integer(runtime_measurements.database_pool_capacity)
    assert is_integer(runtime_measurements.database_pool_ready)
    assert is_integer(runtime_measurements.database_pool_queue)
    assert is_float(runtime_measurements.database_pool_utilization)
    assert is_integer(runtime_measurements.durable_event_count)
    assert is_integer(runtime_measurements.durable_event_bytes)
    assert runtime_measurements.viewer_count >= 0
    assert runtime_measurements.live_view_count == runtime_measurements.viewer_count
    assert runtime_measurements.beam_process_count > 0
    assert runtime_measurements.coordinator_restart_count >= 0
    assert runtime_measurements.database_pool_capacity >= runtime_measurements.database_pool_ready
    assert runtime_measurements.database_pool_queue >= 0
    assert runtime_measurements.database_pool_utilization >= 0.0
    assert runtime_measurements.database_pool_utilization <= 1.0
    assert runtime_measurements.durable_event_count >= 1
    assert runtime_measurements.durable_event_bytes >= 0
  end

  test "dashboard metrics cover every Worldloom operations measurement" do
    metric_names = Enum.map(Telemetry.metrics(), & &1.name)

    assert [:worldloom, :loom, :commit, :count] in metric_names
    assert [:worldloom, :loom, :commit, :duration] in metric_names
    assert [:worldloom, :loom, :coordinator, :start, :count] in metric_names
    assert [:worldloom, :signals, :feed, :count] in metric_names
    assert [:worldloom, :signals, :feed, :duration] in metric_names
    assert [:worldloom, :signals, :retry, :count] in metric_names
    assert [:worldloom, :signals, :buffer, :depth] in metric_names
    assert [:worldloom, :runtime, :viewer_count] in metric_names
    assert [:worldloom, :runtime, :live_view_count] in metric_names
    assert [:worldloom, :runtime, :beam_process_count] in metric_names
    assert [:worldloom, :runtime, :coordinator_alive] in metric_names
    assert [:worldloom, :runtime, :coordinator_restart_count] in metric_names
    assert [:worldloom, :runtime, :database_pool_capacity] in metric_names
    assert [:worldloom, :runtime, :database_pool_ready] in metric_names
    assert [:worldloom, :runtime, :database_pool_queue] in metric_names
    assert [:worldloom, :runtime, :database_pool_utilization] in metric_names
    assert [:worldloom, :runtime, :durable_event_count] in metric_names
    assert [:worldloom, :runtime, :durable_event_bytes] in metric_names
  end

  test "keeps WebSocket transport details outside exported metrics" do
    assert Code.ensure_loaded?(Mint.WebSocket)

    signal_metrics =
      Enum.filter(Telemetry.metrics(), fn metric ->
        Enum.take(metric.name, 2) == [:worldloom, :signals]
      end)

    refute Enum.any?(Telemetry.metrics(), fn metric ->
             :mint in metric.name or :mint_web_socket in metric.name
           end)

    assert signal_metrics != []

    for metric <- signal_metrics do
      assert Enum.all?(metric.tags, &(&1 in [:source, :status, :operation]))
    end
  end

  test "runtime measurement stays available while supervised dependencies are starting" do
    handler_id = {__MODULE__, make_ref()}
    test_process = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:worldloom, :runtime],
        fn event_name, measurements, metadata, _handler_config ->
          send(test_process, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             Telemetry.measure_runtime(
               viewer_counter: fn -> raise ArgumentError, "presence is starting" end,
               durable_storage: fn -> raise RuntimeError, "repo is starting" end
             )

    assert_receive {:telemetry, [:worldloom, :runtime],
                    %{
                      viewer_count: 0,
                      live_view_count: 0,
                      durable_event_count: 0,
                      durable_event_bytes: 0
                    }, %{}},
                   500
  end

  test "operations logs exclude visitor and upstream secrets" do
    private_fields = [
      "Must Disappear Page Title",
      "Must Disappear User",
      "signed-visitor-identity",
      "203.0.113.24",
      "_worldloom_key=private-cookie",
      "private-stream-cursor",
      ~s("private-etag")
    ]

    Logger.metadata(
      user_text: Enum.at(private_fields, 0),
      upstream_user: Enum.at(private_fields, 1),
      visitor_identity: Enum.at(private_fields, 2),
      raw_ip: Enum.at(private_fields, 3),
      cookie: Enum.at(private_fields, 4),
      cursor: Enum.at(private_fields, 5),
      etag: Enum.at(private_fields, 6)
    )

    captured_log =
      capture_log(fn ->
        Telemetry.record_feed(:wikimedia, :failure,
          duration: 31,
          count: 0,
          attempt: 2
        )
      end)

    assert captured_log =~ "Worldloom feed unavailable"
    Enum.each(private_fields, &refute(captured_log =~ &1))
  end

  defp start_coordinator do
    topic = "loom:telemetry-test:#{System.unique_integer([:positive, :monotonic])}"

    start_supervised!(
      {CoordinatorTestStore,
       delegate: Store,
       commit_snapshot: CoordinatorTestStore.empty_snapshot(Store.highest_sequence())}
    )

    {:ok, coordinator} =
      Coordinator.start_link(name: nil, topic: topic, store: CoordinatorTestStore)

    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator) end)
    coordinator
  end

  defp source_event do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: "telemetry-revision-#{System.unique_integer([:positive])}",
      occurred_at: ~U[2026-08-03 12:00:00.000000Z],
      lane: 0.4,
      intensity: 0.6,
      payload: %{"summary" => "A telemetry-safe revision entered the weave"}
    })
  end

  defp checkpoint do
    %{
      source: "wikimedia",
      cursor: "telemetry-cursor",
      etag: nil,
      last_successful_at: ~U[2026-08-03 12:01:00.000000Z],
      metadata: %{}
    }
  end
end
