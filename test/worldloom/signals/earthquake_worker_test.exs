defmodule Worldloom.Signals.EarthquakeWorkerTest do
  use Worldloom.DataCase

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Signals.EarthquakeWorker
  alias Worldloom.Signals.FeedHealth
  alias Worldloom.Signals.HealthRegistry

  @fixture "test/support/fixtures/feeds/usgs.json"
  @now ~U[2026-08-03 12:30:00.000000Z]

  test "polls immediately, submits normalized events, and saves the response ETag in the checkpoint" do
    attach_feed_telemetry()
    test_process = self()
    body = read_fixture()
    registry = start_health_registry()

    client = fn url, options ->
      send(test_process, {:request, url, options})
      {:ok, %{status: 200, body: body, etag: ~s("quake-etag")}}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint})
      :ok
    end

    worker = start_worker(client: client, buffer: buffer, health_registry: registry)

    assert_receive {:request, "https://example.test/usgs", options}, 500
    assert options[:etag] == nil

    assert_receive {:submission, events, checkpoint}, 500
    assert length(events) == 3
    assert checkpoint.source == "usgs"
    assert checkpoint.etag == ~s("quake-etag")
    assert checkpoint.last_successful_at == @now
    assert checkpoint.metadata["generated_at"] == body["metadata"]["generated"]
    assert_receive {:timer, ^worker, :poll, 60_000}, 500

    assert_receive {:feed_telemetry, %{count: 3, duration: duration},
                    %{source: :usgs, status: :success, attempt: 0}},
                   500

    assert is_integer(duration) and duration >= 0

    observation = HealthRegistry.current(registry).usgs
    assert observation.connection == :connected
    assert observation.last_contact_at == @now
    assert observation.last_activity_at == @now

    marker = "private-usgs-checkpoint-marker"

    projection =
      FeedHealth.project(
        %{
          observations: HealthRegistry.current(registry),
          checkpoints: [
            %{
              checkpoint
              | etag: marker,
                last_successful_at: DateTime.add(@now, -10, :minute),
                metadata: %{"private" => marker}
            }
          ]
        },
        @now
      )

    assert projection.usgs == %{state: :live, observed_at: @now}
    refute inspect(projection) =~ marker
  end

  test "restores ETag, treats 304 as successful contact, and never writes the checkpoint itself" do
    insert_checkpoint("usgs", %{
      etag: ~s("saved-etag"),
      metadata: %{"generated_at" => 1_754_224_200_000}
    })

    test_process = self()

    client = fn _url, options ->
      send(test_process, {:request_options, options})
      {:ok, %{status: 304, body: "", etag: ~s("saved-etag")}}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint, self()})

      receive do
        :release_submission -> :ok
      end
    end

    worker = start_worker(client: client, buffer: buffer)

    assert_receive {:request_options, options}, 500
    assert options[:etag] == ~s("saved-etag")
    assert_receive {:submission, [], checkpoint, blocked_worker}, 500
    persisted_contact = Repo.get!(FeedCheckpoint, "usgs").last_successful_at
    assert DateTime.compare(persisted_contact, ~U[2026-08-03 11:00:00Z]) == :eq
    send(blocked_worker, :release_submission)
    assert checkpoint.last_successful_at == @now
    assert checkpoint.metadata == %{"generated_at" => 1_754_224_200_000}
    assert_receive {:timer, ^worker, :poll, 60_000}, 500
  end

  test "malformed bodies do not submit or move the restored ETag" do
    attach_feed_telemetry()
    insert_checkpoint("usgs", %{etag: ~s("saved-etag")})
    test_process = self()

    client = fn _url, _options ->
      {:ok, %{status: 200, body: %{"features" => "bad"}, etag: ~s("new")}}
    end

    buffer = fn _events, _checkpoint -> send(test_process, :unexpected_submission) end
    worker = start_worker(client: client, buffer: buffer)

    refute_receive :unexpected_submission, 100
    assert_receive {:timer, ^worker, :poll, 1_000}, 500
    assert Repo.get!(FeedCheckpoint, "usgs").etag == ~s("saved-etag")

    assert_receive {:feed_telemetry, %{count: 0, duration: duration},
                    %{source: :usgs, status: :failure, attempt: 0}},
                   500

    assert is_integer(duration) and duration >= 0
  end

  test "uses independent capped backoff and resets only after durable contact" do
    test_process = self()
    attempts = start_agent(fn -> 0 end)
    submissions = start_agent(fn -> 0 end)
    registry = start_health_registry()
    sibling = start_supervised!({Task, fn -> Process.sleep(:infinity) end})

    client = fn _url, _options ->
      attempt = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)

      if attempt < 2 do
        {:error, :unavailable}
      else
        {:ok, %{status: 304, body: "", etag: ~s("recovered-etag")}}
      end
    end

    buffer = fn events, checkpoint ->
      submission = Agent.get_and_update(submissions, fn count -> {count, count + 1} end)
      send(test_process, {:contact_attempt, submission, events, checkpoint})
      if submission == 0, do: {:error, :database_down}, else: :ok
    end

    worker =
      start_worker(
        client: client,
        buffer: buffer,
        health_registry: registry,
        random: fn -> 0.5 end
      )

    assert_receive {:timer, ^worker, :poll, 1_000}, 500
    send(worker, :poll)
    assert_receive {:timer, ^worker, :poll, 2_000}, 500
    send(worker, :poll)

    assert_receive {:contact_attempt, 0, [], failed_checkpoint}, 500
    assert failed_checkpoint.etag == ~s("recovered-etag")
    assert_receive {:timer, ^worker, :poll, 4_000}, 500

    failed_observation = HealthRegistry.current(registry).usgs
    assert failed_observation.retries == 3
    assert failed_observation.last_reason == :persistence
    assert failed_observation.last_contact_at == nil
    assert failed_observation.last_activity_at == nil

    send(worker, :poll)
    assert_receive {:contact_attempt, 1, [], checkpoint}, 500
    assert checkpoint.etag == ~s("recovered-etag")
    assert_receive {:timer, ^worker, :poll, 60_000}, 500

    assert :sys.get_state(worker).attempt == 0
    assert Process.alive?(sibling)

    observation = HealthRegistry.current(registry).usgs
    assert observation.retries == 3
    assert observation.last_reason == :persistence
    assert observation.connection == :connected
    assert observation.last_contact_at == @now
  end

  defp attach_feed_telemetry do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:worldloom, :signals, :feed],
        fn _event, measurements, metadata, test_process ->
          send(test_process, {:feed_telemetry, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp start_worker(overrides) do
    test_process = self()

    timer = fn process, message, delay ->
      send(test_process, {:timer, process, message, delay})
      make_ref()
    end

    options =
      Keyword.merge(
        [
          name: nil,
          url: "https://example.test/usgs",
          interval_ms: 60_000,
          clock: fn -> @now end,
          random: fn -> 0.5 end,
          timer: timer
        ],
        overrides
      )

    options =
      Keyword.put_new_lazy(options, :health_registry, fn -> start_health_registry() end)

    {:ok, worker} = EarthquakeWorker.start_link(options)
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)
    worker
  end

  defp insert_checkpoint(source, overrides) do
    attributes =
      Map.merge(
        %{
          source: source,
          cursor: nil,
          etag: nil,
          last_successful_at: ~U[2026-08-03 11:00:00Z],
          metadata: %{}
        },
        overrides
      )

    %FeedCheckpoint{}
    |> FeedCheckpoint.changeset(attributes)
    |> Repo.insert!()
  end

  defp read_fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp start_agent(initializer) do
    start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [initializer]}})
  end

  defp start_health_registry do
    start_supervised!(%{
      id: make_ref(),
      start: {HealthRegistry, :start_link, [[name: nil, monitor: nil, clock: fn -> @now end]]}
    })
  end
end
