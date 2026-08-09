defmodule Worldloom.Signals.DrandWorkerTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.DrandWorker
  alias Worldloom.Signals.FeedHealth
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.TestSupport.FakeDrandClient

  @genesis_time 1_700_000_000

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
