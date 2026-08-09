defmodule Worldloom.Signals.BlueskyRecovery do
  @derive {Inspect, except: [:committed_cursor, :fingerprints]}
  @enforce_keys [:committed_cursor, :fingerprints]
  defstruct committed_cursor: nil, fingerprints: MapSet.new()

  @type t :: %__MODULE__{
          committed_cursor: non_neg_integer() | nil,
          fingerprints: MapSet.t(binary())
        }

  @rewind_microseconds 5_000_000
  @replay_horizon_microseconds 60_000_000
  @fingerprint_capacity 4_096

  @spec new(non_neg_integer() | nil, DateTime.t()) ::
          {:replay, non_neg_integer(), t()} | {:live_tail, {:gap, atom()}, t()}
  def new(committed_cursor, %DateTime{} = receipt_at) do
    receipt_cursor = DateTime.to_unix(receipt_at, :microsecond)

    cond do
      is_nil(committed_cursor) ->
        {:live_tail, {:gap, :missing_checkpoint}, state(nil)}

      not is_integer(committed_cursor) or committed_cursor < 0 ->
        {:live_tail, {:gap, :invalid_checkpoint}, state(nil)}

      committed_cursor > receipt_cursor ->
        {:live_tail, {:gap, :future_checkpoint}, state(nil)}

      receipt_cursor - committed_cursor > @replay_horizon_microseconds ->
        {:live_tail, {:gap, :replay_horizon_exceeded}, state(nil)}

      true ->
        replay_cursor = max(0, committed_cursor - @rewind_microseconds)
        {:replay, replay_cursor, state(committed_cursor)}
    end
  end

  def new(_committed_cursor, _receipt_at) do
    raise ArgumentError, "receipt time must be a DateTime"
  end

  @spec observe(t(), non_neg_integer(), binary()) ::
          {:ok, t()} | {:drop, atom(), t()}
  def observe(%__MODULE__{} = recovery, cursor, identity_material)
      when is_integer(cursor) and cursor >= 0 and is_binary(identity_material) and
             byte_size(identity_material) > 0 do
    cond do
      is_integer(recovery.committed_cursor) and cursor <= recovery.committed_cursor ->
        {:drop, :committed, recovery}

      true ->
        observe_fingerprint(recovery, :crypto.hash(:sha256, identity_material))
    end
  end

  def observe(%__MODULE__{} = recovery, _cursor, _identity_material),
    do: {:drop, :invalid_observation, recovery}

  defp observe_fingerprint(recovery, fingerprint) do
    cond do
      MapSet.member?(recovery.fingerprints, fingerprint) ->
        {:drop, :duplicate, recovery}

      MapSet.size(recovery.fingerprints) >= @fingerprint_capacity ->
        {:drop, :fingerprint_capacity, recovery}

      true ->
        {:ok, %{recovery | fingerprints: MapSet.put(recovery.fingerprints, fingerprint)}}
    end
  end

  defp state(committed_cursor) do
    %__MODULE__{committed_cursor: committed_cursor, fingerprints: MapSet.new()}
  end
end
