defmodule Worldloom.Signals.DrandWorkerTest do
  use Worldloom.DataCase, async: false

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.CoordinatorTestStore
  alias Worldloom.Loom.Event
  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Loom.Instruction
  alias Worldloom.Loom.Store
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.DrandClient
  alias Worldloom.Signals.DrandWorker
  alias Worldloom.Signals.FeedHealth
  alias Worldloom.Signals.HealthMonitor
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.TestSupport.FakeDrandClient

  @fixtures "test/support/fixtures/feeds"
  @genesis_time 1_700_000_000
  @quicknet_origin "https://api.drand.sh"
  @quicknet_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
  @quicknet_info_path "/v2/chains/#{@quicknet_chain_hash}/info"
  @quicknet_round_path "/v2/chains/#{@quicknet_chain_hash}/rounds/42"
  @round_time ~U[2023-08-23 15:11:30.000000Z]

  test "persists one exact public round end to end and replays idempotently" do
    test_process = self()
    start_independent_store()

    health =
      start_supervised!({HealthRegistry, name: nil, monitor: nil, clock: fn -> @round_time end})

    coordinator =
      start_supervised!(
        {Coordinator,
         name: nil,
         bootstrap: :empty,
         store: CoordinatorTestStore,
         topic: "loom:drand-vertical:#{System.unique_integer([:positive, :monotonic])}"}
      )

    buffer =
      start_supervised!(
        {Buffer,
         name: nil,
         coordinator: coordinator,
         health_registry: health,
         clock: fn -> 0 end,
         timer: fn destination, message, delay ->
           send(test_process, {:buffer_timer, destination, message, delay})
           make_ref()
         end}
      )

    request = injected_quicknet_request(test_process)
    first_worker = start_real_worker(buffer, health, request)

    assert_receive {:drand_request, :chain_info}, 500
    assert_receive {:drand_request, {:round, 42}}, 500
    drain_once(buffer)
    assert eventually(fn -> :sys.get_state(first_worker).committed_round == 42 end)

    stored =
      Repo.one!(
        from event in Event,
          where: event.source == "drand" and event.external_id == "drand-round:42"
      )

    assert Map.take(stored, [
             :kind,
             :source,
             :external_id,
             :occurred_at,
             :render_version,
             :render_seed,
             :lane,
             :intensity,
             :payload
           ]) == %{
             kind: "randomness",
             source: "drand",
             external_id: "drand-round:42",
             occurred_at: @round_time,
             render_version: 2,
             render_seed: 1_560_607_657,
             lane: 0.2388,
             intensity: 0.6,
             payload: %{
               "round" => 42,
               "summary" => "drand Quicknet round 42",
               "visual" => %{
                 "bend" => -0.036716,
                 "pulse" => 0.009241,
                 "spread" => 0.547957
               }
             }
           }

    assert Instruction.from_event(stored) == %{
             "sequence" => stored.id,
             "kind" => "randomness",
             "source" => "drand",
             "occurred_at" => "2023-08-23T15:11:30.000000Z",
             "render_version" => 2,
             "seed" => 1_560_607_657,
             "lane" => 0.2388,
             "intensity" => 0.6,
             "visual" => %{
               "bend" => -0.036716,
               "pulse" => 0.009241,
               "spread" => 0.547957
             },
             "summary" => "drand Quicknet round 42",
             "metrics" => %{"round" => 42}
           }

    assert Repo.get!(FeedCheckpoint, "drand") |> Map.take([:cursor, :metadata]) == %{
             cursor: "42",
             metadata: %{}
           }

    snapshot = Coordinator.current_snapshot(coordinator)
    assert Enum.any?(snapshot.display_events, &(&1.id == stored.id))
    assert snapshot.commit_watermark == stored.id

    GenServer.stop(first_worker)

    replay_worker = start_real_worker(buffer, health, request)
    assert_receive {:drand_request, :chain_info}, 500
    assert_receive {:drand_request, {:round, 42}}, 500
    drain_once(buffer)
    assert eventually(fn -> :sys.get_state(replay_worker).committed_round == 42 end)

    assert Repo.aggregate(
             from(
               event in Event,
               where: event.source == "drand" and event.external_id == "drand-round:42"
             ),
             :count
           ) == 1

    assert Coordinator.highest_sequence(coordinator) == stored.id

    monitor =
      start_supervised!(
        {HealthMonitor,
         name: nil,
         enabled: false,
         observation_loader: fn -> HealthRegistry.current(health) end,
         broadcaster: fn _health -> :ok end,
         clock: fn -> @round_time end,
         timer: fn _destination, _message, _delay -> make_ref() end}
      )

    assert HealthMonitor.current(monitor).drand == %{state: :live, observed_at: @round_time}
  end

  test "polls each expected round once and ages durable activity to stale after twelve seconds" do
    now = time_for_round(3, 500)
    context = start_worker(now, committed_round: nil)

    assert_receive {:drand_fetch, 3}, 500
    assert_receive {:buffer_submit, [event], checkpoint}, 500
    assert event.source == :drand
    assert event.external_id == "drand-round:3"
    assert event.payload == %{"round" => 3, "summary" => "drand Quicknet round 3"}
    assert DateTime.compare(event.occurred_at, time_for_round(3)) == :eq

    assert checkpoint == %{
             source: "drand",
             cursor: "3",
             etag: nil,
             last_successful_at: now,
             metadata: %{}
           }

    poll = scheduled_poll(context.worker, 2_500)
    send(context.worker, poll)
    refute_receive {:drand_fetch, _round}, 50
    refute_receive {:buffer_submit, _events, _checkpoint}, 50
    next_poll = scheduled_poll(context.worker, 2_500)

    set_clock(context.clock, time_for_round(4))
    send(context.worker, poll)
    refute_receive {:drand_fetch, _round}, 50

    send(context.worker, next_poll)
    assert_receive {:drand_fetch, 4}, 500
    assert_receive {:buffer_submit, [next_event], %{cursor: "4"}}, 500
    assert next_event.external_id == "drand-round:4"

    observations = HealthRegistry.current(context.health)
    assert observations.drand.last_activity_at == time_for_round(4)

    projection =
      FeedHealth.project(
        %{observations: observations, checkpoints: []},
        DateTime.add(time_for_round(4), 13, :second)
      )

    assert projection.drand == %{state: :stale, observed_at: time_for_round(4)}
  end

  test "recovers at most twenty missing rounds in strict ascending order without batching" do
    context = start_worker(time_for_round(120), committed_round: 100)

    for round <- 101..120 do
      assert_receive {:drand_fetch, ^round}, 500
      assert_receive {:buffer_submit, [event], checkpoint}, 500
      assert event.external_id == "drand-round:#{round}"
      assert checkpoint.cursor == Integer.to_string(round)
      assert checkpoint.metadata == %{}
    end

    refute_receive {:drand_fetch, _round}, 50
    assert :sys.get_state(context.worker).committed_round == 120

    observation = HealthRegistry.current(context.health).drand
    assert observation.recovered_windows == 19
    assert observation.drops == 0
  end

  test "jumps to the live round and records the skipped interval when recovery exceeds the cap" do
    context = start_worker(time_for_round(125), committed_round: 100)

    assert_receive {:drand_fetch, 125}, 500
    assert_receive {:buffer_submit, [event], checkpoint}, 500
    assert event.external_id == "drand-round:125"
    assert checkpoint.cursor == "125"
    assert checkpoint.metadata == %{"skipped_rounds" => 24}
    refute_receive {:drand_fetch, _round}, 50

    observation = HealthRegistry.current(context.health).drand
    assert observation.drops == 1
    assert observation.last_reason == :replay
    assert observation.recovered_windows == 0
  end

  test "sanitizes a future checkpoint instead of suppressing live rounds" do
    context = start_worker(time_for_round(10), committed_round: 11)

    assert_receive {:drand_fetch, 10}, 500
    assert_receive {:buffer_submit, [event], checkpoint}, 500
    assert event.external_id == "drand-round:10"
    assert checkpoint.cursor == "10"
    assert eventually(fn -> :sys.get_state(context.worker).committed_round == 10 end)
  end

  test "sanitizes a non-integer checkpoint before recovery arithmetic" do
    context = start_worker(time_for_round(10), committed_round: 9.0)

    assert_receive {:drand_fetch, 10}, 500
    assert_receive {:buffer_submit, [_event], %{cursor: "10"}}, 500
    assert eventually(fn -> :sys.get_state(context.worker).committed_round == 10 end)
  end

  test "retries an unavailable round with independent capped backoff and resets after success" do
    client =
      start_supervised!(
        {FakeDrandClient,
         owner: self(),
         schedule: schedule(),
         responses: %{10 => [{:error, :unavailable}, {:error, :unavailable}, :ok]}}
      )

    sibling = start_supervised!({Task, fn -> Process.sleep(:infinity) end})
    context = start_worker(time_for_round(10), committed_round: 9, client: client)

    assert_receive {:drand_fetch, 10}, 500
    first_retry = scheduled_poll(context.worker, 1_000)
    assert :sys.get_state(context.worker).committed_round == 9

    send(context.worker, first_retry)
    assert_receive {:drand_fetch, 10}, 500
    second_retry = scheduled_poll(context.worker, 2_000)

    send(context.worker, second_retry)
    assert_receive {:drand_fetch, 10}, 500
    assert_receive {:buffer_submit, [event], %{cursor: "10"}}, 500
    assert event.external_id == "drand-round:10"
    assert :sys.get_state(context.worker).attempt == 0
    assert Process.alive?(sibling)

    observation = HealthRegistry.current(context.health).drand
    assert observation.retries == 2
    assert observation.last_reason == :transport
  end

  test "does not advance the committed round until Buffer accepts durability" do
    test_process = self()

    responses =
      start_supervised!(
        {Agent, fn -> [{:error, :capacity}, :ok] end},
        id: {:buffer_responses, make_ref()}
      )

    buffer = fn events, checkpoint ->
      send(test_process, {:buffer_attempt, events, checkpoint})
      Agent.get_and_update(responses, fn [response | remaining] -> {response, remaining} end)
    end

    context =
      start_worker(time_for_round(10), committed_round: 9, buffer: buffer)

    assert_receive {:drand_fetch, 10}, 500
    assert_receive {:buffer_attempt, [_event], %{cursor: "10"}}, 500
    retry_poll = scheduled_poll(context.worker, 1_000)
    assert :sys.get_state(context.worker).committed_round == 9

    send(context.worker, retry_poll)
    assert_receive {:drand_fetch, 10}, 500
    assert_receive {:buffer_attempt, [_event], %{cursor: "10"}}, 500
    assert eventually(fn -> :sys.get_state(context.worker).committed_round == 10 end)

    observation = HealthRegistry.current(context.health).drand
    assert observation.retries == 1
    assert observation.last_reason == :persistence
  end

  test "retries client initialization without starting a second source process" do
    client = start_supervised!({FakeDrandClient, owner: self(), schedule: schedule()})

    factory =
      start_supervised!(
        {FakeDrandClient, owner: self(), new_responses: [{:error, :unavailable}, {:ok, client}]}
      )

    context =
      start_worker(time_for_round(7),
        committed_round: 6,
        client: nil,
        client_options: [factory: factory]
      )

    assert_receive :drand_client_new, 500
    reconnect = scheduled_connect(context.worker, 1_000)
    assert :sys.get_state(context.worker).client == nil

    send(context.worker, reconnect)
    assert_receive :drand_client_new, 500
    assert_receive {:drand_fetch, 7}, 500
    assert_receive {:buffer_submit, [_event], %{cursor: "7"}}, 500
    assert eventually(fn -> :sys.get_state(context.worker).committed_round == 7 end)
  end

  test "redacts every OTP status field that could carry an edge response" do
    marker = "private-drand-response-marker"

    formatted =
      DrandWorker.format_status(%{
        state: %{client_options: [private: marker]},
        message: {:round, marker},
        reason: {:error, marker},
        log: [{:in, marker}]
      })

    refute inspect(formatted) =~ marker
    assert formatted == %{state: :redacted, message: :redacted, reason: :redacted, log: :redacted}
  end

  defp start_real_worker(buffer, health, request) do
    {:ok, worker} =
      DrandWorker.start_link(
        name: nil,
        client_module: DrandClient,
        client_options: [origins: [@quicknet_origin], request: request],
        committed_round: nil,
        buffer: fn events, checkpoint -> Buffer.submit(buffer, events, checkpoint) end,
        health_registry: health,
        clock: fn -> @round_time end,
        random: fn -> 0.5 end,
        timer: fn _destination, _message, _delay -> make_ref() end
      )

    on_exit(fn ->
      if Process.alive?(worker), do: GenServer.stop(worker)
    end)

    worker
  end

  defp start_independent_store do
    original_repo = Repo.get_dynamic_repo()

    {:ok, independent_repo} =
      Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 4)

    Process.unlink(independent_repo)
    Repo.put_dynamic_repo(independent_repo)
    clear_vertical_slice_rows()

    on_exit(fn ->
      if Process.alive?(independent_repo) do
        Repo.put_dynamic_repo(independent_repo)
        clear_vertical_slice_rows()
        Supervisor.stop(independent_repo)
      end

      Repo.put_dynamic_repo(original_repo)
    end)

    start_supervised!({CoordinatorTestStore, delegate: Store, repo: independent_repo})
  end

  defp clear_vertical_slice_rows do
    Repo.delete_all(
      from event in Event,
        where: event.source == "drand" and event.external_id == "drand-round:42"
    )

    Repo.delete_all(from checkpoint in FeedCheckpoint, where: checkpoint.source == "drand")
  end

  defp injected_quicknet_request(test_process) do
    chain_info = File.read!(Path.join(@fixtures, "drand_chain_info.json"))

    round =
      @fixtures
      |> Path.join("drand_rounds.json")
      |> File.read!()
      |> Jason.decode!()
      |> Enum.find(&(Map.fetch!(&1, "round") == 42))
      |> Jason.encode!()

    fn url, _options ->
      case url do
        @quicknet_origin <> @quicknet_info_path ->
          send(test_process, {:drand_request, :chain_info})
          json_response(chain_info)

        @quicknet_origin <> @quicknet_round_path ->
          send(test_process, {:drand_request, {:round, 42}})
          json_response(round)

        _unexpected ->
          {:error, :unavailable}
      end
    end
  end

  defp json_response(body) do
    {:ok,
     Req.Response.new(
       status: 200,
       headers: [{"content-type", "application/json; charset=utf-8"}],
       body: body
     )}
  end

  defp drain_once(buffer) do
    assert_receive {:buffer_timer, ^buffer, {:drain, _token} = message, 250}, 500
    send(buffer, message)
    assert eventually(fn -> Buffer.depth(buffer) == 0 end)
  end

  defp start_worker(now, options) do
    test_process = self()
    clock = start_supervised!({Agent, fn -> now end})

    health =
      start_supervised!(
        {HealthRegistry, name: nil, monitor: nil, clock: fn -> Agent.get(clock, & &1) end}
      )

    client =
      case Keyword.fetch(options, :client) do
        {:ok, configured} -> configured
        :error -> start_supervised!({FakeDrandClient, owner: self(), schedule: schedule()})
      end

    buffer =
      Keyword.get(options, :buffer, fn events, checkpoint ->
        send(test_process, {:buffer_submit, events, checkpoint})
        :ok
      end)

    timer = fn destination, message, delay ->
      send(test_process, {:timer_scheduled, destination, message, delay})
      make_ref()
    end

    worker_options = [
      name: nil,
      client_module: FakeDrandClient,
      client_options: Keyword.get(options, :client_options, []),
      committed_round: Keyword.fetch!(options, :committed_round),
      buffer: buffer,
      health_registry: health,
      clock: fn -> Agent.get(clock, & &1) end,
      random: fn -> 0.5 end,
      timer: timer
    ]

    worker_options =
      if is_nil(client), do: worker_options, else: [{:client, client} | worker_options]

    worker = start_supervised!({DrandWorker, worker_options})

    %{worker: worker, health: health, clock: clock}
  end

  defp schedule, do: %{period: 3, genesis_time: @genesis_time}

  defp time_for_round(round, offset_ms \\ 0) do
    @genesis_time
    |> Kernel.+((round - 1) * 3)
    |> DateTime.from_unix!(:second)
    |> DateTime.add(offset_ms, :millisecond)
  end

  defp set_clock(clock, now), do: Agent.update(clock, fn _previous -> now end)

  defp scheduled_poll(worker, expected_delay) do
    assert_receive {:timer_scheduled, ^worker, {:poll, _token} = message, ^expected_delay}, 500
    message
  end

  defp scheduled_connect(worker, expected_delay) do
    assert_receive {:timer_scheduled, ^worker, {:connect, _token} = message, ^expected_delay}, 500
    message
  end

  defp eventually(assertion, attempts \\ 50)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    if assertion.() do
      true
    else
      Process.sleep(5)
      eventually(assertion, attempts - 1)
    end
  end
end
