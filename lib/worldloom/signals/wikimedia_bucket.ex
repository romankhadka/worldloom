defmodule Worldloom.Signals.WikimediaBucket do
  @enforce_keys [:window_start]
  defstruct window_start: nil,
            cursor: nil,
            count: 0,
            total_absolute_byte_delta: 0,
            languages: %{},
            edit_types: %{}

  @type t :: %__MODULE__{
          window_start: DateTime.t(),
          cursor: String.t() | nil,
          count: non_neg_integer(),
          total_absolute_byte_delta: non_neg_integer(),
          languages: %{String.t() => non_neg_integer()},
          edit_types: %{String.t() => non_neg_integer()}
        }

  @window_seconds 4
  @offset_seconds 0
  @lateness_seconds 1
  @uint32_max 4_294_967_295
  @edit_types ~w(edit new log categorize external)

  @spec new(DateTime.t()) :: t()
  def new(%DateTime{} = observed_at) do
    case DateTime.shift_zone(observed_at, "Etc/UTC") do
      {:ok, utc_observed_at} -> %__MODULE__{window_start: window_start(utc_observed_at)}
      {:error, reason} -> raise ArgumentError, "invalid bucket time: #{inspect(reason)}"
    end
  end

  def new(_observed_at), do: raise(ArgumentError, "bucket time must be a DateTime")

  @spec add(t(), map()) ::
          {:ok, t()}
          | {:future, t(), t()}
          | {:heartbeat, t()}
          | {:drop, atom(), t()}
  def add(%__MODULE__{} = bucket, %{data: ""} = frame) do
    {:heartbeat, advance_cursor(bucket, frame[:id])}
  end

  def add(%__MODULE__{} = bucket, %{data: encoded_event} = frame)
      when is_binary(encoded_event) do
    with {:ok, upstream_event} <- Jason.decode(encoded_event),
         {:ok, sanitized_event} <- sanitize_event(upstream_event) do
      event_window_start = window_start(sanitized_event.occurred_at)

      case DateTime.compare(event_window_start, bucket.window_start) do
        :lt ->
          {:drop, :late_event, bucket}

        :eq ->
          {:ok, aggregate(bucket, sanitized_event, frame[:id])}

        :gt ->
          future_bucket =
            event_window_start
            |> new()
            |> aggregate(sanitized_event, frame[:id])

          {:future, bucket, future_bucket}
      end
    else
      {:error, %Jason.DecodeError{}} -> {:drop, :malformed_json, bucket}
      {:error, _reason} -> {:drop, :invalid_event, bucket}
    end
  end

  def add(%__MODULE__{} = bucket, _frame), do: {:drop, :invalid_frame, bucket}

  @spec elapsed?(t(), DateTime.t()) :: boolean()
  def elapsed?(%__MODULE__{} = bucket, %DateTime{} = observed_at) do
    with {:ok, utc_observed_at} <- DateTime.shift_zone(observed_at, "Etc/UTC") do
      close_at =
        DateTime.add(
          bucket.window_start,
          @window_seconds + @lateness_seconds,
          :second
        )

      DateTime.compare(utc_observed_at, close_at) in [:eq, :gt]
    else
      {:error, _reason} -> false
    end
  end

  def elapsed?(%__MODULE__{}, _observed_at), do: false

  @spec flush(t()) :: map() | :empty
  def flush(%__MODULE__{count: 0}), do: :empty

  def flush(%__MODULE__{} = bucket) do
    %{
      window_start: bucket.window_start,
      cursor: bucket.cursor,
      count: bucket.count,
      total_absolute_byte_delta: bucket.total_absolute_byte_delta,
      languages: bucket.languages,
      edit_types: bucket.edit_types
    }
  end

  defp window_start(occurred_at) do
    unix_second = DateTime.to_unix(occurred_at, :second)
    unix_start = unix_second - Integer.mod(unix_second - @offset_seconds, @window_seconds)
    DateTime.from_unix!(unix_start, :second)
  end

  defp sanitize_event(%{
         "meta" => %{"dt" => encoded_time},
         "type" => edit_type,
         "wiki" => wiki,
         "length" => %{"old" => old_length, "new" => new_length}
       })
       when is_binary(encoded_time) and edit_type in @edit_types and is_binary(wiki) and
              is_integer(old_length) and old_length >= 0 and is_integer(new_length) and
              new_length >= 0 do
    with {:ok, occurred_at, _offset} <- DateTime.from_iso8601(encoded_time),
         {:ok, utc_occurred_at} <- DateTime.shift_zone(occurred_at, "Etc/UTC"),
         {:ok, language} <- language_code(wiki) do
      {:ok,
       %{
         occurred_at: utc_occurred_at,
         language: language,
         edit_type: edit_type,
         absolute_byte_delta: min(abs(new_length - old_length), @uint32_max)
       }}
    else
      _invalid -> {:error, :invalid_event}
    end
  end

  defp sanitize_event(_upstream_event), do: {:error, :invalid_event}

  defp language_code(wiki) do
    case Regex.run(~r/^([a-z0-9-]{1,16})wiki$/, wiki, capture: :all_but_first) do
      [language] -> {:ok, language}
      _invalid -> {:error, :invalid_language}
    end
  end

  defp aggregate(bucket, sanitized_event, cursor) do
    %{
      bucket
      | cursor: next_cursor(bucket.cursor, cursor),
        count: saturated_add(bucket.count, 1),
        total_absolute_byte_delta:
          saturated_add(bucket.total_absolute_byte_delta, sanitized_event.absolute_byte_delta),
        languages: increment(bucket.languages, sanitized_event.language),
        edit_types: increment(bucket.edit_types, sanitized_event.edit_type)
    }
  end

  defp increment(counters, key),
    do: Map.update(counters, key, 1, &saturated_add(&1, 1))

  defp saturated_add(left, right), do: min(left + right, @uint32_max)
  defp advance_cursor(bucket, cursor), do: %{bucket | cursor: next_cursor(bucket.cursor, cursor)}
  defp next_cursor(_existing_cursor, cursor) when is_binary(cursor) and cursor != "", do: cursor
  defp next_cursor(existing_cursor, _cursor), do: existing_cursor
end
