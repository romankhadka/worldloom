defmodule Worldloom.Signals.WikimediaBucket do
  @enforce_keys [:second]
  defstruct second: nil,
            cursor: nil,
            count: 0,
            total_absolute_byte_delta: 0,
            languages: %{},
            edit_types: %{}

  @type t :: %__MODULE__{
          second: DateTime.t(),
          cursor: String.t() | nil,
          count: non_neg_integer(),
          total_absolute_byte_delta: non_neg_integer(),
          languages: %{String.t() => non_neg_integer()},
          edit_types: %{String.t() => non_neg_integer()}
        }

  @edit_types ~w(edit new log categorize external)

  @spec new(DateTime.t()) :: t()
  def new(%DateTime{} = second) do
    case DateTime.shift_zone(second, "Etc/UTC") do
      {:ok, utc_second} -> %__MODULE__{second: DateTime.truncate(utc_second, :second)}
      {:error, reason} -> raise ArgumentError, "invalid bucket second: #{inspect(reason)}"
    end
  end

  def new(_second), do: raise(ArgumentError, "bucket second must be a DateTime")

  @spec add(t(), map()) ::
          {:ok, t()}
          | {:flush, t(), t()}
          | {:heartbeat, t()}
          | {:drop, atom(), t()}
  def add(%__MODULE__{} = bucket, %{data: ""} = frame) do
    {:heartbeat, advance_cursor(bucket, frame[:id])}
  end

  def add(%__MODULE__{} = bucket, %{data: encoded_event} = frame)
      when is_binary(encoded_event) do
    with {:ok, upstream_event} <- Jason.decode(encoded_event),
         {:ok, sanitized_event} <- sanitize_event(upstream_event) do
      case DateTime.compare(sanitized_event.second, bucket.second) do
        :lt ->
          {:drop, :late_event, bucket}

        :eq ->
          {:ok, aggregate(bucket, sanitized_event, frame[:id])}

        :gt ->
          next_bucket =
            sanitized_event.second
            |> new()
            |> aggregate(sanitized_event, frame[:id])

          {:flush, bucket, next_bucket}
      end
    else
      {:error, %Jason.DecodeError{}} -> {:drop, :malformed_json, bucket}
      {:error, _reason} -> {:drop, :invalid_event, bucket}
    end
  end

  def add(%__MODULE__{} = bucket, _frame), do: {:drop, :invalid_frame, bucket}

  @spec flush(t()) :: map() | :empty
  def flush(%__MODULE__{count: 0}), do: :empty

  def flush(%__MODULE__{} = bucket) do
    %{
      second: bucket.second,
      cursor: bucket.cursor,
      count: bucket.count,
      total_absolute_byte_delta: bucket.total_absolute_byte_delta,
      languages: bucket.languages,
      edit_types: bucket.edit_types
    }
  end

  defp sanitize_event(%{
         "meta" => %{"dt" => encoded_second},
         "type" => edit_type,
         "wiki" => wiki,
         "length" => %{"old" => old_length, "new" => new_length}
       })
       when is_binary(encoded_second) and edit_type in @edit_types and is_binary(wiki) and
              is_integer(old_length) and old_length >= 0 and is_integer(new_length) and
              new_length >= 0 do
    with {:ok, second, _offset} <- DateTime.from_iso8601(encoded_second),
         {:ok, utc_second} <- DateTime.shift_zone(second, "Etc/UTC"),
         {:ok, language} <- language_code(wiki) do
      {:ok,
       %{
         second: DateTime.truncate(utc_second, :second),
         language: language,
         edit_type: edit_type,
         absolute_byte_delta: abs(new_length - old_length)
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
        count: bucket.count + 1,
        total_absolute_byte_delta:
          bucket.total_absolute_byte_delta + sanitized_event.absolute_byte_delta,
        languages: Map.update(bucket.languages, sanitized_event.language, 1, &(&1 + 1)),
        edit_types: Map.update(bucket.edit_types, sanitized_event.edit_type, 1, &(&1 + 1))
    }
  end

  defp advance_cursor(bucket, cursor), do: %{bucket | cursor: next_cursor(bucket.cursor, cursor)}
  defp next_cursor(_existing_cursor, cursor) when is_binary(cursor) and cursor != "", do: cursor
  defp next_cursor(existing_cursor, _cursor), do: existing_cursor
end
