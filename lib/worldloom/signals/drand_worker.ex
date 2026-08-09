defmodule Worldloom.Signals.DrandWorker do
  use GenServer

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Repo
  alias Worldloom.Signals.Backoff
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.DrandClient
  alias Worldloom.Signals.DrandWorker.State
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.Normalizer
  alias WorldloomWeb.Telemetry

  @source :drand
  @source_name "drand"
  @maximum_recovery_rounds 20
  @json_safe_max 9_007_199_254_740_991
  @maximum_unix_second 253_402_300_799

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, registration_options(name))
  end

  @impl true
  def init(options) do
    client_module = Keyword.get(options, :client_module, DrandClient)
    client = Keyword.get(options, :client)
    schedule = if client, do: validated_schedule!(client_module.schedule(client))

    state = %State{
      client: client,
      client_module: client_module,
      client_options: Keyword.get(options, :client_options, []),
      schedule: schedule,
      committed_round: initial_round(options),
      buffer: Keyword.get(options, :buffer, &Buffer.submit/2),
      health_registry: Keyword.get(options, :health_registry, HealthRegistry),
      clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
      random: Keyword.get(options, :random, &:rand.uniform/0),
      timer: Keyword.get(options, :timer, &Process.send_after/3),
      timer_token: nil,
      timer_kind: nil,
      attempt: 0
    }

    send(self(), if(client, do: :poll, else: :connect))
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, %State{client: nil} = state), do: connect(clear_timer(state))

  def handle_info(
        {:connect, token},
        %State{client: nil, timer_token: token, timer_kind: :connect} = state
      ),
      do: connect(clear_timer(state))

  def handle_info({:connect, _stale_token}, state), do: {:noreply, state}
  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info(:poll, %State{client: client} = state) when not is_nil(client),
    do: poll(clear_timer(state))

  def handle_info(
        {:poll, token},
        %State{client: client, timer_token: token, timer_kind: :poll} = state
      )
      when not is_nil(client),
      do: poll(clear_timer(state))

  def handle_info({:poll, _stale_token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, _state} -> {:state, :redacted}
      {:message, _message} -> {:message, :redacted}
      {:reason, _reason} -> {:reason, :redacted}
      {:log, _log} -> {:log, :redacted}
      key_value -> key_value
    end)
  end

  defp connect(state) do
    started_at = System.monotonic_time()

    case state.client_module.new(state.client_options) do
      {:ok, client} ->
        schedule = validated_schedule!(state.client_module.schedule(client))

        Telemetry.record_feed(@source, :success,
          duration: System.monotonic_time() - started_at,
          count: 0,
          attempt: state.attempt
        )

        send(self(), :poll)
        {:noreply, %{state | client: client, schedule: schedule, attempt: 0}}

      {:error, :unavailable} ->
        Telemetry.record_feed(@source, :failure,
          duration: System.monotonic_time() - started_at,
          count: 0,
          attempt: state.attempt
        )

        {:noreply, schedule_retry(state, :connect, :connection, :transport)}
    end
  end

  defp poll(state) do
    started_at = System.monotonic_time()
    receipt_at = validated_clock!(state.clock.())
    expected_round = expected_round(state.schedule, receipt_at)
    {rounds, skipped_rounds, prepared_state} = recovery_plan(state, expected_round)

    case fetch_rounds(prepared_state, rounds, expected_round, skipped_rounds, receipt_at) do
      {:ok, completed_state} ->
        Telemetry.record_feed(@source, :success,
          duration: System.monotonic_time() - started_at,
          count: length(rounds),
          attempt: completed_state.attempt
        )

        updated = %{completed_state | attempt: 0}
        {:noreply, schedule_next_round(updated, expected_round, receipt_at)}

      {:error, operation, drop_reason, failed_state} ->
        Telemetry.record_feed(@source, :failure,
          duration: System.monotonic_time() - started_at,
          count: 0,
          attempt: failed_state.attempt
        )

        timer_kind = if(is_nil(failed_state.client), do: :connect, else: :poll)
        {:noreply, schedule_retry(failed_state, timer_kind, operation, drop_reason)}
    end
  end

  defp fetch_rounds(state, rounds, expected_round, skipped_rounds, receipt_at) do
    Enum.reduce_while(rounds, {:ok, state}, fn round, {:ok, current} ->
      case fetch_round(current, round, expected_round, skipped_rounds, receipt_at) do
        {:ok, advanced} -> {:cont, {:ok, advanced}}
        {:error, operation, reason, failed} -> {:halt, {:error, operation, reason, failed}}
      end
    end)
  end

  defp fetch_round(state, round, expected_round, skipped_rounds, receipt_at) do
    case state.client_module.fetch_round(state.client, round) do
      {:ok, accepted_round} ->
        contacted = state |> record_health(:connected) |> record_health(:contact)

        with {:ok, event} <- Normalizer.drand_round(state.schedule, accepted_round),
             :ok <- state.buffer.([event], checkpoint(round, skipped_rounds, receipt_at)) do
          advanced =
            contacted
            |> Map.put(:committed_round, round)
            |> record_health({:activity, 1})
            |> maybe_record_recovery(round, expected_round)
            |> maybe_record_gap(skipped_rounds)

          {:ok, advanced}
        else
          {:error, :invalid_round} ->
            {:error, :connection, :malformed, contacted}

          {:error, _reason} ->
            {:error, :persistence, :persistence, contacted}
        end

      {:error, :unavailable} ->
        {:error, :connection, :transport, record_health(state, :disconnected)}
    end
  end

  defp recovery_plan(state, nil), do: {[], 0, state}

  defp recovery_plan(%State{committed_round: nil} = state, expected_round),
    do: {[expected_round], 0, state}

  defp recovery_plan(%State{committed_round: expected_round} = state, expected_round),
    do: {[], 0, state}

  defp recovery_plan(%State{committed_round: committed_round} = state, expected_round)
       when committed_round > expected_round,
       do: {[expected_round], 0, %{state | committed_round: nil}}

  defp recovery_plan(%State{committed_round: committed_round} = state, expected_round) do
    missing_rounds = expected_round - committed_round

    if missing_rounds <= @maximum_recovery_rounds do
      {Enum.to_list((committed_round + 1)..expected_round), 0, state}
    else
      {[expected_round], missing_rounds - 1, state}
    end
  end

  defp expected_round(%{period: 3, genesis_time: genesis_time}, receipt_at) do
    unix_second = DateTime.to_unix(receipt_at, :second)

    if unix_second < genesis_time do
      nil
    else
      min(div(unix_second - genesis_time, 3) + 1, @json_safe_max)
    end
  end

  defp schedule_next_round(state, expected_round, receipt_at) do
    next_round = if is_integer(expected_round), do: expected_round + 1, else: 1
    next_round = min(next_round, @json_safe_max)
    due_second = state.schedule.genesis_time + (next_round - 1) * state.schedule.period
    now_millisecond = DateTime.to_unix(receipt_at, :millisecond)
    delay = max(due_second * 1_000 - now_millisecond, 1)
    schedule_timer(state, :poll, delay)
  end

  defp schedule_retry(state, timer_kind, operation, drop_reason) do
    delay = Backoff.delay(state.attempt, state.random.())

    Telemetry.record_retry(@source, operation,
      attempt: state.attempt + 1,
      delay: delay
    )

    state
    |> record_health({:drop, drop_reason})
    |> record_health({:retry, 1})
    |> Map.put(:attempt, state.attempt + 1)
    |> schedule_timer(timer_kind, delay)
  end

  defp schedule_timer(state, timer_kind, delay) do
    token = make_ref()
    state.timer.(self(), {timer_kind, token}, delay)
    %{state | timer_token: token, timer_kind: timer_kind}
  end

  defp checkpoint(round, skipped_rounds, receipt_at) do
    metadata = if skipped_rounds > 0, do: %{"skipped_rounds" => skipped_rounds}, else: %{}

    %{
      source: @source_name,
      cursor: Integer.to_string(round),
      etag: nil,
      last_successful_at: receipt_at,
      metadata: metadata
    }
  end

  defp maybe_record_recovery(state, round, expected_round) when round < expected_round,
    do: record_health(state, {:recovery, 1})

  defp maybe_record_recovery(state, _round, _expected_round), do: state

  defp maybe_record_gap(state, skipped_rounds) when skipped_rounds > 0,
    do: record_health(state, {:drop, :replay})

  defp maybe_record_gap(state, _skipped_rounds), do: state

  defp record_health(state, observation) do
    :ok = HealthRegistry.record(state.health_registry, @source, observation)
    state
  end

  defp clear_timer(state), do: %{state | timer_token: nil, timer_kind: nil}

  defp validated_schedule!(%{period: 3, genesis_time: genesis_time} = schedule)
       when is_integer(genesis_time) and genesis_time in 1..@maximum_unix_second,
       do: schedule

  defp validated_schedule!(_schedule), do: raise(ArgumentError, "invalid drand schedule")

  defp validated_clock!(%DateTime{} = receipt_at), do: receipt_at
  defp validated_clock!(_invalid), do: raise(ArgumentError, "drand clock must return a DateTime")

  defp initial_round(options) do
    checkpoint_cursor =
      if Keyword.has_key?(options, :committed_round) do
        Keyword.get(options, :committed_round)
      else
        case Repo.get(FeedCheckpoint, @source_name) do
          nil -> nil
          checkpoint -> checkpoint.cursor
        end
      end

    parse_round(checkpoint_cursor)
  end

  defp parse_round(nil), do: nil
  defp parse_round(round) when is_integer(round) and round in 1..@json_safe_max, do: round

  defp parse_round(round) when is_binary(round) do
    case Integer.parse(round) do
      {parsed, ""} when parsed in 1..@json_safe_max -> parsed
      _invalid -> nil
    end
  end

  defp parse_round(_round), do: nil
  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
