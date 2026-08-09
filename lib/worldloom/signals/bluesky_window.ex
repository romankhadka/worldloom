defmodule Worldloom.Signals.BlueskyWindow do
  alias Worldloom.Signals.BoundedCounter

  @enforce_keys [:window_start]
  defstruct window_start: nil,
            total_actions: 0,
            original_posts: 0,
            replies: 0,
            reposts: 0,
            creates: 0,
            updates: 0,
            deletes: 0,
            truncated: false

  @type t :: %__MODULE__{
          window_start: DateTime.t(),
          total_actions: non_neg_integer(),
          original_posts: non_neg_integer(),
          replies: non_neg_integer(),
          reposts: non_neg_integer(),
          creates: non_neg_integer(),
          updates: non_neg_integer(),
          deletes: non_neg_integer(),
          truncated: boolean()
        }

  @window_seconds 4
  @offset_seconds 1
  @lateness_seconds 1
  @replay_horizon_microseconds 60_000_000
  @future_skew_microseconds 5_000_000
  @collections ~w(app.bsky.feed.post app.bsky.feed.repost)
  @operations ~w(create update delete)
  @operation_fields %{"create" => :creates, "update" => :updates, "delete" => :deletes}

  @spec new(DateTime.t()) :: t()
  def new(%DateTime{} = observed_at) do
    %__MODULE__{
      window_start: BoundedCounter.window_start(observed_at, @window_seconds, @offset_seconds)
    }
  end

  def new(_observed_at), do: raise(ArgumentError, "window time must be a DateTime")

  @spec add(t(), map(), DateTime.t()) ::
          {:ok, t()} | {:flush, t(), t()} | {:drop, atom(), t()}
  def add(%__MODULE__{} = window, frame, %DateTime{} = receipt_at) when is_map(frame) do
    with {:ok, observation} <- sanitize(frame),
         :ok <- validate_provider_time(observation.occurred_at, receipt_at) do
      event_window_start =
        BoundedCounter.window_start(
          observation.occurred_at,
          @window_seconds,
          @offset_seconds
        )

      case DateTime.compare(event_window_start, window.window_start) do
        :lt ->
          {:drop, :late_event, window}

        :eq ->
          {:ok, aggregate(window, observation)}

        :gt ->
          next_window =
            observation.occurred_at
            |> new()
            |> aggregate(observation)

          {:flush, window, next_window}
      end
    else
      {:error, reason} -> {:drop, reason, window}
    end
  end

  def add(%__MODULE__{} = window, _frame, %DateTime{}),
    do: {:drop, :invalid_frame, window}

  def add(%__MODULE__{}, _frame, _receipt_at),
    do: raise(ArgumentError, "receipt time must be a DateTime")

  @spec elapsed?(t(), DateTime.t()) :: boolean()
  def elapsed?(%__MODULE__{} = window, %DateTime{} = observed_at) do
    with {:ok, utc_observed_at} <- DateTime.shift_zone(observed_at, "Etc/UTC") do
      close_at =
        DateTime.add(
          window.window_start,
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
  def flush(%__MODULE__{total_actions: 0}), do: :empty

  def flush(%__MODULE__{} = window) do
    %{
      window_start: window.window_start,
      total_actions: window.total_actions,
      original_posts: window.original_posts,
      replies: window.replies,
      reposts: window.reposts,
      creates: window.creates,
      updates: window.updates,
      deletes: window.deletes,
      truncated: window.truncated
    }
  end

  defp sanitize(%{"kind" => kind}) when kind != "commit",
    do: {:error, :unsupported_kind}

  defp sanitize(%{
         "kind" => "commit",
         "time_us" => time_us,
         "commit" =>
           %{
             "collection" => collection,
             "operation" => operation
           } = commit
       }) do
    with :ok <- validate_collection(collection),
         :ok <- validate_operation(operation),
         :ok <- validate_record(commit, operation),
         {:ok, occurred_at} <- provider_time(time_us) do
      {:ok,
       %{
         occurred_at: occurred_at,
         category: category(collection, operation, commit),
         operation: operation
       }}
    end
  end

  defp sanitize(%{"kind" => "commit", "time_us" => time_us})
       when not is_integer(time_us),
       do: {:error, :invalid_timestamp}

  defp sanitize(%{"kind" => "commit"}), do: {:error, :invalid_frame}
  defp sanitize(_frame), do: {:error, :unsupported_kind}

  defp validate_collection(collection) when collection in @collections, do: :ok
  defp validate_collection(_collection), do: {:error, :unsupported_collection}
  defp validate_operation(operation) when operation in @operations, do: :ok
  defp validate_operation(_operation), do: {:error, :unsupported_operation}

  defp validate_record(%{"record" => record}, operation)
       when operation in ["create", "update"] and is_map(record),
       do: :ok

  defp validate_record(_commit, operation) when operation in ["create", "update"],
    do: {:error, :invalid_record}

  defp validate_record(commit, "delete") do
    case Map.fetch(commit, "record") do
      :error -> :ok
      {:ok, record} when is_map(record) -> :ok
      {:ok, _record} -> {:error, :invalid_record}
    end
  end

  defp provider_time(time_us) when is_integer(time_us) do
    case DateTime.from_unix(time_us, :microsecond) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  defp provider_time(_time_us), do: {:error, :invalid_timestamp}

  defp validate_provider_time(occurred_at, receipt_at) do
    occurred_cursor = DateTime.to_unix(occurred_at, :microsecond)
    receipt_cursor = DateTime.to_unix(receipt_at, :microsecond)

    cond do
      occurred_cursor < receipt_cursor - @replay_horizon_microseconds ->
        {:error, :timestamp_too_old}

      occurred_cursor > receipt_cursor + @future_skew_microseconds ->
        {:error, :timestamp_in_future}

      true ->
        :ok
    end
  end

  defp category("app.bsky.feed.repost", _operation, _commit), do: :reposts

  defp category("app.bsky.feed.post", "delete", commit)
       when not is_map_key(commit, "record"),
       do: nil

  defp category("app.bsky.feed.post", _operation, commit) do
    record = Map.get(commit, "record", %{})
    if is_map(record["reply"]), do: :replies, else: :original_posts
  end

  defp aggregate(window, observation) do
    window
    |> increment(:total_actions)
    |> increment(Map.fetch!(@operation_fields, observation.operation))
    |> increment(observation.category)
  end

  defp increment(window, nil), do: window

  defp increment(window, field) do
    {count, truncated} = BoundedCounter.add(Map.fetch!(window, field), 1)

    window
    |> Map.put(field, count)
    |> Map.put(:truncated, window.truncated or truncated)
  end
end
