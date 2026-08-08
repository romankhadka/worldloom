defmodule Worldloom.Loom.Store do
  import Ecto.Query

  alias Worldloom.Loom.Event
  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Loom.LiveProjection
  alias Worldloom.Loom.LiveSnapshot
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.VisualParameters
  alias Worldloom.Repo

  @live_sources ~w(wikimedia usgs visitor)
  @live_source_limit 240
  @memory_lookback_seconds 24 * 60 * 60
  @live_window_seconds 60
  @maximum_limit 600

  @spec commit_external([SourceEvent.t()], map() | nil) ::
          {:ok, [Event.t()]} | {:error, term()}
  def commit_external(events, checkpoint)
      when is_list(events) and (is_map(checkpoint) or is_nil(checkpoint)) do
    Repo.transaction(fn ->
      with {:ok, validated_events} <- validate_external_events(events, checkpoint),
           {:ok, inserted_events} <- insert_external_events(validated_events),
           {:ok, _checkpoint} <- upsert_checkpoint(checkpoint) do
        inserted_events
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def commit_external(_events, _checkpoint),
    do: {:error, {:invalid_arguments, :external_commit}}

  @spec commit_visitor(SourceEvent.t(), String.t()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def commit_visitor(%SourceEvent{source: :visitor} = event, request_nonce)
      when is_binary(request_nonce) and byte_size(request_nonce) > 0 do
    case SourceEvent.new(Map.from_struct(event)) do
      {:ok, validated_event} ->
        validated_event
        |> event_attributes(request_nonce)
        |> Map.delete(:inserted_at)
        |> then(&Event.changeset(%Event{}, &1))
        |> Repo.insert()

      {:error, reason} ->
        raise ArgumentError, "invalid visitor event: #{inspect(reason)}"
    end
  end

  def commit_visitor(_event, _request_nonce),
    do: raise(ArgumentError, "expected a visitor event and non-empty request nonce")

  @spec latest(pos_integer()) :: [Event.t()]
  def latest(limit \\ 400)

  def latest(limit) when is_integer(limit) and limit in 1..@maximum_limit do
    Event
    |> order_by([event], desc: event.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def latest(_limit), do: invalid_limit!()

  @spec live_snapshot(DateTime.t() | nil) :: LiveSnapshot.t()
  def live_snapshot(previous_window_end \\ nil) do
    case Repo.transaction(fn ->
           Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
           load_live_snapshot(previous_window_end)
         end) do
      {:ok, snapshot} ->
        snapshot

      {:error, reason} ->
        raise "live snapshot transaction rolled back unexpectedly: #{inspect(reason)}"
    end
  end

  defp load_live_snapshot(previous_window_end) do
    commit_watermark = highest_sequence()

    if commit_watermark == 0 do
      %LiveSnapshot{
        window_end: nil,
        commit_watermark: 0,
        display_events: [],
        memory_events: [],
        ambient: nil
      }
    else
      window_end = live_window_end(commit_watermark, previous_window_end)
      candidates = live_candidates(window_end, commit_watermark)
      ambient = ambient_before(commit_watermark)

      LiveProjection.build(candidates, ambient, commit_watermark, previous_window_end)
    end
  end

  @spec fetch(pos_integer()) :: {:ok, Event.t()} | :error
  def fetch(sequence) when is_integer(sequence) and sequence > 0 do
    case Repo.get(Event, sequence) do
      nil -> :error
      event -> {:ok, event}
    end
  end

  def fetch(_sequence), do: raise(ArgumentError, "sequence must be a positive integer")

  @spec around(pos_integer(), pos_integer()) :: [Event.t()]
  def around(sequence, limit \\ 500)

  def around(sequence, limit)
      when is_integer(sequence) and sequence > 0 and is_integer(limit) and
             limit in 1..@maximum_limit do
    earlier = rows_before(sequence, div(limit, 2))
    current_and_later = rows_from(sequence, limit - length(earlier))

    if length(earlier) + length(current_and_later) < limit do
      rows_before(sequence, limit - length(current_and_later)) ++ current_and_later
    else
      earlier ++ current_and_later
    end
  end

  def around(sequence, limit) do
    validate_sequence!(sequence)
    validate_limit!(limit)
  end

  @spec unquote(:after)(non_neg_integer(), non_neg_integer(), pos_integer()) :: [Event.t()]
  def unquote(:after)(sequence, through_sequence, limit \\ 600)

  def unquote(:after)(sequence, through_sequence, limit)
      when is_integer(sequence) and sequence >= 0 and is_integer(through_sequence) and
             through_sequence >= sequence and is_integer(limit) and limit in 1..@maximum_limit do
    Event
    |> where([event], event.id > ^sequence and event.id <= ^through_sequence)
    |> order_by([event], asc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def unquote(:after)(sequence, through_sequence, limit) do
    validate_non_negative_sequence!(sequence)
    validate_non_negative_sequence!(through_sequence)

    if through_sequence < sequence do
      raise ArgumentError, "through sequence must not precede sequence"
    end

    validate_limit!(limit)
  end

  @spec before(pos_integer(), pos_integer()) :: [Event.t()]
  def before(sequence, limit \\ 400)

  def before(sequence, limit)
      when is_integer(sequence) and sequence > 0 and is_integer(limit) and
             limit in 1..@maximum_limit do
    rows_before(sequence, limit)
  end

  def before(sequence, limit) do
    validate_sequence!(sequence)
    validate_limit!(limit)
  end

  @spec wikimedia_before(pos_integer(), pos_integer()) :: [Event.t()]
  def wikimedia_before(sequence, limit \\ 12)

  def wikimedia_before(sequence, limit)
      when is_integer(sequence) and sequence > 0 and is_integer(limit) and
             limit in 1..@maximum_limit do
    Event
    |> where([event], event.source == "wikimedia" and event.id <= ^sequence)
    |> order_by([event], desc: event.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def wikimedia_before(sequence, limit) do
    validate_sequence!(sequence)
    validate_limit!(limit)
  end

  @spec ambient_before(pos_integer()) :: Event.t() | nil
  def ambient_before(sequence) when is_integer(sequence) and sequence > 0 do
    Event
    |> where([event], event.source == "open_meteo" and event.id <= ^sequence)
    |> order_by([event], desc: event.id)
    |> limit(1)
    |> Repo.one()
  end

  def ambient_before(_sequence), do: raise(ArgumentError, "sequence must be a positive integer")

  @spec chapter(Date.t(), pos_integer()) :: [Event.t()]
  def chapter(date, limit \\ 600)

  def chapter(%Date{} = date, limit)
      when is_integer(limit) and limit in 1..@maximum_limit do
    day_start = DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
    next_day_start = DateTime.add(day_start, 1, :day)

    Event
    |> where(
      [event],
      event.occurred_at >= ^day_start and event.occurred_at < ^next_day_start
    )
    |> order_by([event], asc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def chapter(%Date{}, limit), do: validate_limit!(limit)
  def chapter(_date, _limit), do: raise(ArgumentError, "date must be a Date")

  @spec chapters(pos_integer()) :: [map()]
  def chapters(limit \\ 30)

  def chapters(limit) when is_integer(limit) and limit in 1..@maximum_limit do
    Event
    |> group_by([event], fragment("date(?)", event.occurred_at))
    |> order_by([event], desc: fragment("date(?)", event.occurred_at))
    |> limit(^limit)
    |> select([event], %{
      date: type(fragment("date(?)", event.occurred_at), :date),
      count: count(event.id),
      first_sequence: min(event.id),
      last_sequence: max(event.id)
    })
    |> Repo.all()
  end

  def chapters(_limit), do: invalid_limit!()

  @spec highest_sequence() :: non_neg_integer()
  def highest_sequence do
    Repo.one(from event in Event, select: max(event.id)) || 0
  end

  defp live_window_end(commit_watermark, previous_window_end) do
    latest_occurrence =
      Event
      |> where(
        [event],
        event.id <= ^commit_watermark and fragment("? <> 'open_meteo'", event.source)
      )
      |> order_by([event], desc: event.occurred_at, desc: event.id)
      |> limit(1)
      |> select([event], event.occurred_at)
      |> Repo.one()

    latest_occurrence
    |> truncate_window_end()
    |> later_window_end(previous_window_end)
  end

  defp truncate_window_end(nil), do: nil
  defp truncate_window_end(occurred_at), do: DateTime.truncate(occurred_at, :second)

  defp later_window_end(nil, previous_window_end), do: previous_window_end
  defp later_window_end(window_end, nil), do: window_end

  defp later_window_end(window_end, previous_window_end) do
    case DateTime.compare(window_end, previous_window_end) do
      :lt -> previous_window_end
      :eq -> window_end
      :gt -> window_end
    end
  end

  defp live_candidates(nil, _commit_watermark), do: []

  defp live_candidates(window_end, commit_watermark) do
    window_start = DateTime.add(window_end, -@live_window_seconds, :second)
    memory_start = DateTime.add(window_end, -@memory_lookback_seconds, :second)
    window_ceiling = window_end |> DateTime.truncate(:second) |> DateTime.add(1, :second)

    display_candidates =
      Enum.flat_map(@live_sources, fn source ->
        live_source_rows(source, window_start, window_ceiling, commit_watermark)
      end)

    contextual_candidates =
      contextual_source_rows("usgs", memory_start, window_start, commit_watermark, 1) ++
        contextual_source_rows("visitor", memory_start, window_start, commit_watermark, 3)

    display_candidates ++ contextual_candidates
  end

  defp live_source_rows(source, window_start, window_ceiling, commit_watermark) do
    Event
    |> where(
      [event],
      event.source == ^source and event.id <= ^commit_watermark and
        event.occurred_at >= ^window_start and event.occurred_at < ^window_ceiling
    )
    |> order_by([event], desc: event.occurred_at, desc: event.id)
    |> limit(^@live_source_limit)
    |> Repo.all()
  end

  defp contextual_source_rows(
         source,
         memory_start,
         window_start,
         commit_watermark,
         limit
       ) do
    Event
    |> where(
      [event],
      event.source == ^source and event.id <= ^commit_watermark and
        event.occurred_at >= ^memory_start and event.occurred_at < ^window_start
    )
    |> order_by([event], desc: event.occurred_at, desc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp validate_external_events(events, checkpoint) do
    with {:ok, validated_events} <- validate_source_events(events),
         :ok <- validate_external_sources(validated_events, checkpoint) do
      {:ok, validated_events}
    end
  end

  defp validate_source_events(events) do
    Enum.reduce_while(events, {:ok, []}, fn
      %SourceEvent{} = event, {:ok, validated_events} ->
        case SourceEvent.new(Map.from_struct(event)) do
          {:ok, validated_event} ->
            {:cont, {:ok, [validated_event | validated_events]}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_event, reason}}}
        end

      _event, _validated_events ->
        {:halt, {:error, {:invalid_event, {:event, :invalid}}}}
    end)
    |> case do
      {:ok, validated_events} -> {:ok, Enum.reverse(validated_events)}
      error -> error
    end
  end

  defp validate_external_sources(events, checkpoint) do
    checkpoint_source = checkpoint_source(checkpoint)
    event_sources = events |> Enum.map(& &1.source) |> Enum.uniq()

    cond do
      :visitor in event_sources ->
        {:error, {:invalid_event, {:source, :visitor}}}

      event_sources == [] ->
        :ok

      length(event_sources) == 1 and
          (is_nil(checkpoint_source) or Atom.to_string(hd(event_sources)) == checkpoint_source) ->
        :ok

      true ->
        {:error, {:checkpoint_source_mismatch, checkpoint_source}}
    end
  end

  defp checkpoint_source(nil), do: nil
  defp checkpoint_source(checkpoint), do: checkpoint[:source] || checkpoint["source"]

  defp insert_external_events(events) do
    rows = Enum.map(events, &event_attributes(&1, nil))

    {_count, inserted_events} =
      Repo.insert_all(Event, rows,
        on_conflict: :nothing,
        returning: true
      )

    {:ok, Enum.sort_by(inserted_events, & &1.id)}
  end

  defp upsert_checkpoint(attributes) when is_map(attributes) do
    %FeedCheckpoint{}
    |> FeedCheckpoint.changeset(attributes)
    |> Repo.insert(
      conflict_target: :source,
      on_conflict: {:replace, [:cursor, :etag, :last_successful_at, :metadata, :updated_at]},
      returning: true
    )
  end

  defp upsert_checkpoint(nil), do: {:ok, nil}

  defp event_attributes(event, request_nonce) do
    parameters = VisualParameters.for(event, request_nonce)

    %{
      kind: Atom.to_string(event.kind),
      source: Atom.to_string(event.source),
      external_id: event.external_id,
      occurred_at: event.occurred_at,
      render_version: parameters.render_version,
      render_seed: parameters.render_seed,
      lane: event.lane,
      intensity: event.intensity,
      payload: Map.put(event.payload, "visual", parameters.visual),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  defp rows_before(_sequence, 0), do: []

  defp rows_before(sequence, limit) do
    Event
    |> where([event], event.id < ^sequence)
    |> order_by([event], desc: event.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp rows_from(_sequence, 0), do: []

  defp rows_from(sequence, limit) do
    Event
    |> where([event], event.id >= ^sequence)
    |> order_by([event], asc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp validate_sequence!(sequence) when is_integer(sequence) and sequence > 0, do: :ok
  defp validate_sequence!(_sequence), do: raise(ArgumentError, "sequence must be positive")

  defp validate_non_negative_sequence!(sequence)
       when is_integer(sequence) and sequence >= 0,
       do: :ok

  defp validate_non_negative_sequence!(_sequence),
    do: raise(ArgumentError, "sequence must be non-negative")

  defp validate_limit!(limit) when is_integer(limit) and limit in 1..@maximum_limit, do: :ok
  defp validate_limit!(_limit), do: invalid_limit!()

  defp invalid_limit!, do: raise(ArgumentError, "limit must be between 1 and 600")
end
