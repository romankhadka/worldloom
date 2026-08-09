defmodule Worldloom.Signals.SolanaSlotAdapter do
  alias Worldloom.Signals.BoundedCounter

  @derive {Inspect, except: [:pending]}
  @enforce_keys [:window_start]
  defstruct window_start: nil,
            slot_count: 0,
            first_slot: nil,
            last_slot: nil,
            gap_count: 0,
            previous_accepted_slot: nil,
            continuity_anchor: nil,
            truncated: false,
            pending: nil

  @type t :: %__MODULE__{
          window_start: DateTime.t(),
          slot_count: non_neg_integer(),
          first_slot: non_neg_integer() | nil,
          last_slot: non_neg_integer() | nil,
          gap_count: non_neg_integer(),
          previous_accepted_slot: non_neg_integer() | nil,
          continuity_anchor: non_neg_integer() | nil,
          truncated: boolean(),
          pending: t() | nil
        }

  @window_seconds 4
  @offset_seconds 3
  @lateness_seconds 1
  @json_safe_max 9_007_199_254_740_991

  @spec subscription_message() :: map()
  def subscription_message do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => "slotSubscribe"}
  end

  @spec new(DateTime.t(), non_neg_integer() | nil) :: t()
  def new(observed_at, previous_slot \\ nil)

  def new(%DateTime{} = observed_at, previous_slot) do
    if is_nil(previous_slot) or json_safe_integer?(previous_slot) do
      observed_at
      |> window_start()
      |> empty_window_at(previous_slot)
    else
      raise ArgumentError, "previous slot must be a JSON-safe non-negative integer"
    end
  end

  def new(_observed_at, _previous_slot) do
    raise ArgumentError, "window time must be a DateTime"
  end

  @spec add(t(), map(), DateTime.t()) ::
          {:ok, t()} | {:close_required, t()} | {:drop, atom(), t()}
  def add(%__MODULE__{} = state, frame, %DateTime{} = receipt_at) when is_map(frame) do
    with {:ok, slot} <- notification_slot(frame),
         :ok <- slot_order(slot, latest_accepted_slot(state)) do
      route_slot(state, slot, receipt_at)
    else
      {:drop, reason} -> {:drop, reason, state}
      {:error, reason} -> {:drop, reason, state}
    end
  end

  def add(%__MODULE__{} = state, _frame, %DateTime{}),
    do: {:drop, :invalid_notification, state}

  def add(%__MODULE__{}, _frame, _receipt_at) do
    raise ArgumentError, "receipt time must be a DateTime"
  end

  @spec elapsed?(t(), DateTime.t()) :: boolean()
  def elapsed?(%__MODULE__{} = state, %DateTime{} = observed_at) do
    with {:ok, utc_observed_at} <- DateTime.shift_zone(observed_at, "Etc/UTC") do
      close_at =
        DateTime.add(state.window_start, @window_seconds + @lateness_seconds, :second)

      DateTime.compare(utc_observed_at, close_at) in [:eq, :gt]
    else
      {:error, _reason} -> false
    end
  end

  def elapsed?(%__MODULE__{}, _observed_at), do: false

  @spec close(t(), DateTime.t()) :: {:open, t()} | {:flush, map() | :empty, t()}
  def close(%__MODULE__{} = state, %DateTime{} = observed_at) do
    if elapsed?(state, observed_at) do
      {:flush, flush(state), next_state(state, observed_at)}
    else
      {:open, state}
    end
  end

  def close(%__MODULE__{} = state, _observed_at), do: {:open, state}

  @spec flush(t()) :: map() | :empty
  def flush(%__MODULE__{slot_count: 0}), do: :empty

  def flush(%__MODULE__{} = state) do
    %{
      window_start: state.window_start,
      slot_count: state.slot_count,
      first_slot: state.first_slot,
      last_slot: state.last_slot,
      gap_count: state.gap_count,
      truncated: state.truncated,
      continuity_anchor: state.continuity_anchor
    }
  end

  defp notification_slot(%{
         "jsonrpc" => "2.0",
         "method" => "slotNotification",
         "params" => %{
           "subscription" => subscription,
           "result" => %{"slot" => slot, "parent" => parent, "root" => root}
         }
       }) do
    if nonnegative_integer?(subscription) and valid_slot_positions?(slot, parent, root) do
      {:ok, slot}
    else
      {:error, :invalid_notification}
    end
  end

  defp notification_slot(_frame), do: {:error, :invalid_notification}

  defp valid_slot_positions?(0, 0, 0), do: true

  defp valid_slot_positions?(slot, parent, root) do
    json_safe_integer?(slot) and json_safe_integer?(parent) and json_safe_integer?(root) and
      root <= parent and parent < slot
  end

  defp json_safe_integer?(number), do: is_integer(number) and number in 0..@json_safe_max
  defp nonnegative_integer?(number), do: is_integer(number) and number >= 0

  defp slot_order(_slot, nil), do: :ok
  defp slot_order(slot, slot), do: {:drop, :duplicate_slot}
  defp slot_order(slot, previous) when slot < previous, do: {:drop, :backward_slot}
  defp slot_order(_slot, _previous), do: :ok

  defp latest_accepted_slot(%__MODULE__{pending: %__MODULE__{} = pending}),
    do: pending.previous_accepted_slot

  defp latest_accepted_slot(%__MODULE__{} = state), do: state.previous_accepted_slot

  defp route_slot(state, slot, receipt_at) do
    if elapsed?(state, receipt_at) do
      {:close_required, state}
    else
      route_open_slot(state, slot, window_start(receipt_at))
    end
  end

  defp route_open_slot(state, slot, event_window_start) do
    successor_start = DateTime.add(state.window_start, @window_seconds, :second)

    case DateTime.compare(event_window_start, state.window_start) do
      :lt ->
        {:drop, :late_event, state}

      :eq when is_nil(state.pending) ->
        {:ok, aggregate_slot(state, slot)}

      :eq ->
        {:drop, :late_event, state}

      :gt ->
        if DateTime.compare(event_window_start, successor_start) == :eq do
          aggregate_pending(state, slot, successor_start)
        else
          {:drop, :window_ahead, state}
        end
    end
  end

  defp aggregate_pending(state, slot, successor_start) do
    pending = state.pending || empty_window_at(successor_start, state.previous_accepted_slot)
    {:ok, %{state | pending: aggregate_slot(pending, slot)}}
  end

  defp aggregate_slot(state, slot) do
    gap = gap_after(state.previous_accepted_slot, slot)
    {slot_count, slot_truncated?} = BoundedCounter.add(state.slot_count, 1)
    {gap_count, gap_truncated?} = BoundedCounter.add(state.gap_count, gap)

    %{
      state
      | slot_count: slot_count,
        first_slot: state.first_slot || slot,
        last_slot: slot,
        gap_count: gap_count,
        previous_accepted_slot: slot,
        continuity_anchor: continuity_anchor(state),
        truncated: state.truncated or slot_truncated? or gap_truncated?
    }
  end

  defp continuity_anchor(%__MODULE__{slot_count: 0} = state),
    do: state.previous_accepted_slot

  defp continuity_anchor(%__MODULE__{} = state), do: state.continuity_anchor

  defp gap_after(nil, _slot), do: 0
  defp gap_after(previous_slot, slot), do: slot - previous_slot - 1

  defp next_state(%__MODULE__{pending: %__MODULE__{} = pending}, _observed_at),
    do: %{pending | pending: nil}

  defp next_state(%__MODULE__{} = state, observed_at) do
    immediate_successor = DateTime.add(state.window_start, @window_seconds, :second)
    live_window = window_start(observed_at)
    next_window_start = Enum.max([immediate_successor, live_window], DateTime)

    empty_window_at(next_window_start, state.previous_accepted_slot)
  end

  defp empty_window_at(window_start, previous_accepted_slot) do
    %__MODULE__{
      window_start: window_start,
      previous_accepted_slot: previous_accepted_slot
    }
  end

  defp window_start(%DateTime{} = observed_at) do
    BoundedCounter.window_start(observed_at, @window_seconds, @offset_seconds)
  end
end
