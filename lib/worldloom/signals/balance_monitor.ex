defmodule Worldloom.Signals.BalanceMonitor do
  @moduledoc """
  Measures whether eligible public signal sources occurred in recent rolling windows.

  The monitor keeps only ephemeral aggregate timing state. Its telemetry describes
  observed signal balance, not provider availability or an availability guarantee.
  """

  use GenServer

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.Event
  alias Worldloom.Loom.LiveSnapshot
  alias Worldloom.Signals.HealthMonitor

  @quota_sources [:wikimedia, :bluesky, :ripe_ris, :solana, :drand]
  @source_kinds %{
    "wikimedia" => {:wikimedia, "wikimedia"},
    "bluesky" => {:bluesky, "public_activity"},
    "ripe_ris" => {:ripe_ris, "route_change"},
    "solana" => {:solana, "slot"},
    "drand" => {:drand, "randomness"}
  }
  @horizon_seconds 300
  @interval_seconds 10
  @retention_seconds @horizon_seconds + @interval_seconds
  @boundary_interval 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, registration_options(name))
  end

  @impl true
  def init(options) do
    pubsub = Keyword.get(options, :pubsub, Worldloom.PubSub)
    snapshot_topic = Keyword.get(options, :snapshot_topic, Coordinator.topic())
    health_topic = Keyword.get(options, :health_topic, HealthMonitor.topic())

    subscriber =
      Keyword.get(options, :subscriber, fn topic -> Phoenix.PubSub.subscribe(pubsub, topic) end)

    :ok = subscriber.(snapshot_topic)
    :ok = subscriber.(health_topic)

    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)
    snapshot_loader = Keyword.get(options, :snapshot_loader, &Coordinator.current_snapshot/0)
    health_loader = Keyword.get(options, :health_loader, &HealthMonitor.current/0)
    now_second = unix_second(clock.())

    state = %{
      clock: clock,
      eligibility: %{},
      emitter: Keyword.get(options, :emitter, &emit/3),
      live_sources: live_sources(health_loader.()),
      occurrences: %{},
      timer: Keyword.get(options, :timer, &Process.send_after/3)
    }

    initialized_state = record_snapshot(state, snapshot_loader.(), now_second)
    schedule_boundary(initialized_state)
    {:ok, initialized_state}
  end

  @impl true
  def handle_info({:loom_snapshot, %LiveSnapshot{} = snapshot}, state) do
    now_second = unix_second(state.clock.())
    {:noreply, record_snapshot(state, snapshot, now_second)}
  end

  def handle_info({:feed_health, health}, state) do
    {:noreply, %{state | live_sources: live_sources(health)}}
  end

  def handle_info(:balance_boundary, state) do
    now = state.clock.()
    now_second = unix_second(now)

    updated_state =
      state
      |> record_eligibility(now_second)
      |> prune(now_second)

    emit_measurements(updated_state, now_second)
    schedule_boundary(updated_state, now)
    {:noreply, updated_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp record_snapshot(state, %LiveSnapshot{display_events: events}, now_second)
       when is_list(events) do
    occurrences =
      Enum.reduce(events, state.occurrences, fn
        %Event{source: source, kind: kind, occurred_at: %DateTime{} = occurred_at}, acc ->
          case Map.get(@source_kinds, source) do
            {source_atom, ^kind} ->
              occurrence_second = unix_second(occurred_at)

              if retained_second?(occurrence_second, now_second) do
                Map.update(
                  acc,
                  occurrence_second,
                  MapSet.new([source_atom]),
                  &MapSet.put(&1, source_atom)
                )
              else
                acc
              end

            _excluded ->
              acc
          end

        _excluded, acc ->
          acc
      end)

    %{state | occurrences: prune_seconds(occurrences, now_second)}
  end

  defp record_snapshot(state, _snapshot, now_second), do: prune(state, now_second)

  defp record_eligibility(state, now_second) do
    %{state | eligibility: Map.put(state.eligibility, now_second, state.live_sources)}
  end

  defp live_sources(health) when is_map(health) do
    Enum.reduce(@quota_sources, MapSet.new(), fn source, eligible ->
      case Map.get(health, source) do
        %{state: :live} -> MapSet.put(eligible, source)
        _ineligible -> eligible
      end
    end)
  end

  defp live_sources(_health), do: MapSet.new()

  defp emit_measurements(state, now_second) do
    oldest_interval_end = now_second - @horizon_seconds + 1

    Enum.each(@quota_sources, fn source ->
      eligible_interval_ends =
        for {interval_end, eligible_sources} <- state.eligibility,
            interval_end >= oldest_interval_end,
            interval_end <= now_second,
            MapSet.member?(eligible_sources, source),
            do: interval_end

      observed =
        Enum.count(eligible_interval_ends, fn interval_end ->
          occurred_in_interval?(state.occurrences, source, interval_end)
        end)

      state.emitter.(source, observed, length(eligible_interval_ends))
    end)
  end

  defp occurred_in_interval?(occurrences, source, interval_end) do
    interval_start = interval_end - @interval_seconds + 1

    Enum.any?(interval_start..interval_end, fn second ->
      case Map.fetch(occurrences, second) do
        {:ok, sources} -> MapSet.member?(sources, source)
        :error -> false
      end
    end)
  end

  defp prune(state, now_second) do
    %{
      state
      | eligibility: prune_seconds(state.eligibility, now_second),
        occurrences: prune_seconds(state.occurrences, now_second)
    }
  end

  defp prune_seconds(seconds, now_second) do
    Map.filter(seconds, fn {second, _sources} -> retained_second?(second, now_second) end)
  end

  defp retained_second?(second, now_second) do
    second >= now_second - @retention_seconds + 1 and second <= now_second
  end

  defp schedule_boundary(state, now \\ nil) do
    current_time = now || state.clock.()
    state.timer.(self(), :balance_boundary, milliseconds_to_boundary(current_time))
  end

  defp milliseconds_to_boundary(%DateTime{microsecond: {microsecond, _precision}}) do
    elapsed_milliseconds = div(microsecond, 1_000)
    @boundary_interval - rem(elapsed_milliseconds, @boundary_interval)
  end

  defp unix_second(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :second)

  defp emit(source, observed, eligible) do
    :telemetry.execute(
      [:worldloom, :signals, :balance],
      %{observed: observed, eligible: eligible},
      %{source: source}
    )
  end

  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
