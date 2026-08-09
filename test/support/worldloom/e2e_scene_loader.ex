defmodule Worldloom.E2ESceneLoader do
  @moduledoc false

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.Event
  alias Worldloom.Loom.Instruction
  alias Worldloom.Loom.LiveProjection
  alias Worldloom.Repo
  alias Worldloom.E2ESourceEligibility
  alias Worldloom.Signals.HealthMonitor

  @scenes %{
    "balanced" => :all_live,
    "wikimedia-surge" => :all_live,
    "delayed-recovery" => :delayed_recovery,
    "total-outage" => :total_outage,
    "memory-expiry" => :all_live
  }
  @sources ~w(wikimedia bluesky ripe_ris solana drand usgs open_meteo)
  @instruction_keys ~w(sequence kind source occurred_at render_version seed lane intensity visual summary)
  @display_limit 600
  @memory_limit 4
  @ambient_limit 1

  @spec known_scene?(term()) :: boolean()
  def known_scene?(name), do: is_binary(name) and Map.has_key?(@scenes, name)

  @spec load(term(), term()) ::
          {:ok, Worldloom.Loom.LiveSnapshot.t()}
          | {:error, :unknown_scene | :invalid_snapshot}
  def load(name, snapshot) do
    with {:ok, health_profile} <- Map.fetch(@scenes, name),
         {:ok, validated} <- validate_snapshot(snapshot),
         true <- preflight_matches?(validated),
         :ok <- replace_events(validated.events),
         {:ok, authoritative_snapshot} <- restart_coordinator(),
         true <- snapshot_matches?(authoritative_snapshot, validated),
         :ok <- E2ESourceEligibility.enable_all(),
         :ok <- inject_health(health_profile, validated.window_end) do
      broadcast_snapshot(authoritative_snapshot)
      {:ok, authoritative_snapshot}
    else
      :error -> {:error, :unknown_scene}
      _invalid -> {:error, :invalid_snapshot}
    end
  rescue
    _error -> {:error, :invalid_snapshot}
  end

  defp validate_snapshot(
         %{
           "snapshot_version" => 1,
           "window_end" => encoded_window_end,
           "commit_watermark" => commit_watermark,
           "display_events" => display_events,
           "memory_events" => memory_events,
           "ambient" => ambient
         } = snapshot
       )
       when map_size(snapshot) == 6 and is_integer(commit_watermark) and commit_watermark > 0 and
              is_list(display_events) and is_list(memory_events) do
    with {:ok, window_end, 0} <- DateTime.from_iso8601(encoded_window_end),
         true <- DateTime.to_iso8601(window_end) == encoded_window_end,
         {:ok, ambient_events} <- ambient_events(ambient),
         true <- length(display_events) <= @display_limit,
         true <- length(memory_events) <= @memory_limit,
         true <- length(ambient_events) <= @ambient_limit,
         instructions <- display_events ++ memory_events ++ ambient_events,
         true <- instructions != [],
         {:ok, events} <- validate_instructions(instructions),
         true <- unique_sequences?(events),
         true <- Enum.max_by(events, & &1.id).id == commit_watermark do
      {:ok,
       %{
         events: events,
         window_end: window_end,
         commit_watermark: commit_watermark,
         expected: %{
           display_events: display_events,
           memory_events: memory_events,
           ambient: ambient
         }
       }}
    else
      _invalid -> {:error, :invalid_snapshot}
    end
  end

  defp validate_snapshot(_snapshot), do: {:error, :invalid_snapshot}

  defp ambient_events(nil), do: {:ok, []}
  defp ambient_events(ambient) when is_map(ambient), do: {:ok, [ambient]}
  defp ambient_events(_ambient), do: {:error, :invalid_snapshot}

  defp validate_instructions(instructions) do
    Enum.reduce_while(instructions, {:ok, []}, fn instruction, {:ok, events} ->
      case validate_instruction(instruction) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, :invalid_snapshot} -> {:halt, {:error, :invalid_snapshot}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp validate_instruction(instruction) when is_map(instruction) do
    expected_keys =
      if Map.has_key?(instruction, "metrics"),
        do: ["metrics" | @instruction_keys],
        else: @instruction_keys

    with true <- Enum.sort(Map.keys(instruction)) == Enum.sort(expected_keys),
         {:ok, occurred_at, 0} <- DateTime.from_iso8601(instruction["occurred_at"]),
         true <- DateTime.to_iso8601(occurred_at) == instruction["occurred_at"],
         {:ok, attributes} <- event_attributes(instruction, occurred_at),
         changeset <- Event.changeset(%Event{id: instruction["sequence"]}, attributes),
         {:ok, event} <- Ecto.Changeset.apply_action(changeset, :insert),
         event <- %{event | inserted_at: event.occurred_at},
         projected_instruction <- Instruction.from_event(event),
         true <-
           canonical_instruction(projected_instruction) == canonical_instruction(instruction) do
      {:ok, event}
    else
      _invalid -> {:error, :invalid_snapshot}
    end
  rescue
    _error -> {:error, :invalid_snapshot}
  end

  defp validate_instruction(_instruction), do: {:error, :invalid_snapshot}

  defp event_attributes(instruction, occurred_at) do
    occurred_at = microsecond_precision(occurred_at)

    payload =
      %{
        "summary" => instruction["summary"],
        "visual" => instruction["visual"]
      }
      |> maybe_put_metrics(instruction)

    attributes = %{
      kind: instruction["kind"],
      source: instruction["source"],
      external_id: external_id(instruction),
      occurred_at: occurred_at,
      render_version: instruction["render_version"],
      render_seed: instruction["seed"],
      lane: instruction["lane"],
      intensity: instruction["intensity"],
      payload: payload,
      inserted_at: occurred_at
    }

    if valid_visual?(instruction["visual"]) and
         is_integer(instruction["sequence"]) and instruction["sequence"] > 0 and
         instruction["source"] in (@sources ++ ["visitor"]) do
      {:ok, attributes}
    else
      {:error, :invalid_snapshot}
    end
  end

  defp maybe_put_metrics(payload, %{"metrics" => metrics}), do: Map.merge(payload, metrics)
  defp maybe_put_metrics(payload, _instruction), do: payload

  defp external_id(%{"source" => "visitor"}), do: nil

  defp external_id(%{"source" => source, "sequence" => sequence}),
    do: "worldloom-e2e-#{source}-#{sequence}"

  defp valid_visual?(%{"spread" => spread, "bend" => bend, "pulse" => pulse} = visual)
       when map_size(visual) == 3 do
    unit_number?(spread) and unit_number?(pulse) and bounded_number?(bend, -1.0, 1.0)
  end

  defp valid_visual?(_visual), do: false

  defp unit_number?(number), do: bounded_number?(number, 0.0, 1.0)

  defp bounded_number?(number, minimum, maximum) when is_number(number),
    do: number >= minimum and number <= maximum

  defp bounded_number?(_number, _minimum, _maximum), do: false

  defp microsecond_precision(%DateTime{microsecond: {microseconds, _precision}} = occurred_at),
    do: %{occurred_at | microsecond: {microseconds, 6}}

  defp unique_sequences?(events) do
    sequences = Enum.map(events, & &1.id)
    Enum.uniq(sequences) == sequences
  end

  defp replace_events(events) do
    maximum_sequence = events |> Enum.max_by(& &1.id) |> Map.fetch!(:id)
    rows = Enum.map(events, &event_row/1)

    Repo.transaction(fn ->
      Repo.query!("LOCK TABLE loom_events IN ACCESS EXCLUSIVE MODE")
      Repo.delete_all(Event)
      {count, nil} = Repo.insert_all(Event, rows)

      if count != length(rows) do
        Repo.rollback(:incomplete_scene)
      end

      Repo.query!(
        "SELECT setval(pg_get_serial_sequence('loom_events', 'id'), $1, true)",
        [maximum_sequence]
      )
    end)
    |> case do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :invalid_snapshot}
    end
  end

  defp event_row(event) do
    event
    |> Map.from_struct()
    |> Map.take([
      :id,
      :kind,
      :source,
      :external_id,
      :occurred_at,
      :render_version,
      :render_seed,
      :lane,
      :intensity,
      :payload,
      :inserted_at
    ])
  end

  defp restart_coordinator do
    with :ok <- Supervisor.terminate_child(Worldloom.Supervisor, Coordinator),
         {:ok, coordinator} <- Supervisor.restart_child(Worldloom.Supervisor, Coordinator) do
      {:ok, Coordinator.current_snapshot(coordinator)}
    end
  end

  defp snapshot_matches?(snapshot, validated) do
    DateTime.compare(snapshot.window_end, validated.window_end) == :eq and
      snapshot.commit_watermark == validated.commit_watermark and
      canonical_instructions(snapshot.display_events) ==
        canonical_instructions(validated.expected.display_events) and
      canonical_instructions(snapshot.memory_events) ==
        canonical_instructions(validated.expected.memory_events) and
      canonical_instruction(snapshot.ambient) == canonical_instruction(validated.expected.ambient)
  end

  defp preflight_matches?(validated) do
    ambient_sequence =
      case validated.expected.ambient do
        %{"sequence" => sequence} -> sequence
        nil -> nil
      end

    {ambient, candidates} =
      Enum.reduce(validated.events, {nil, []}, fn event, {ambient, candidates} ->
        if event.id == ambient_sequence do
          {event, candidates}
        else
          {ambient, [event | candidates]}
        end
      end)

    candidates
    |> LiveProjection.build(ambient, validated.commit_watermark, nil)
    |> snapshot_matches?(validated)
  end

  defp canonical_instructions(events), do: Enum.map(events, &canonical_instruction/1)

  defp canonical_instruction(%Event{} = event),
    do: event |> Instruction.from_event() |> canonical_instruction()

  defp canonical_instruction(%{"occurred_at" => encoded_occurred_at} = instruction) do
    {:ok, occurred_at, 0} = DateTime.from_iso8601(encoded_occurred_at)
    Map.put(instruction, "occurred_at", DateTime.to_unix(occurred_at, :microsecond))
  end

  defp canonical_instruction(nil), do: nil

  defp inject_health(profile, observed_at) do
    health = health_profile(profile, observed_at)

    :sys.replace_state(HealthMonitor, fn state ->
      %{state | health: health, broadcasted?: true}
    end)

    Phoenix.PubSub.broadcast(
      Worldloom.PubSub,
      HealthMonitor.topic(),
      {:feed_health, health}
    )
  end

  defp health_profile(:all_live, observed_at),
    do: Map.new(@sources, &{String.to_existing_atom(&1), health(:live, observed_at)})

  defp health_profile(:delayed_recovery, observed_at) do
    :all_live
    |> health_profile(observed_at)
    |> Map.put(:ripe_ris, health(:quiet, DateTime.add(observed_at, -21, :second)))
  end

  defp health_profile(:total_outage, _observed_at),
    do: Map.new(@sources, &{String.to_existing_atom(&1), health(:disconnected, nil)})

  defp health(state, observed_at), do: %{state: state, observed_at: observed_at}

  defp broadcast_snapshot(snapshot) do
    Phoenix.PubSub.broadcast(
      Worldloom.PubSub,
      Coordinator.topic(),
      {:loom_snapshot, snapshot}
    )

    :ok
  end
end
