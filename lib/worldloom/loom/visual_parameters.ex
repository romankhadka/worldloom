defmodule Worldloom.Loom.VisualParameters do
  import Bitwise

  alias Worldloom.Loom.SourceEvent

  @javascript_integer_max 2_147_483_647
  @uint32_max 4_294_967_295
  @uint32_mask 0xFFFFFFFF
  @zero_seed_state 0x6D2B79F5

  @spec for(SourceEvent.t(), String.t() | nil) :: %{
          render_version: pos_integer(),
          render_seed: non_neg_integer(),
          visual: %{String.t() => float()}
        }
  def for(%SourceEvent{} = event, request_nonce) do
    identity = visual_identity(event, request_nonce)

    seed =
      :erlang.phash2(
        {event.source, identity, event.occurred_at, event.kind},
        @javascript_integer_max
      )

    initial_state = if seed == 0, do: @zero_seed_state, else: seed
    spread_state = xorshift32(initial_state)
    bend_state = xorshift32(spread_state)
    pulse_state = xorshift32(bend_state)

    %{
      render_version: 1,
      render_seed: seed,
      visual: %{
        "spread" => rounded_unit_float(spread_state),
        "bend" => Float.round(unit_float(bend_state) * 2.0 - 1.0, 6),
        "pulse" => rounded_unit_float(pulse_state)
      }
    }
  end

  def for(_event, _request_nonce), do: raise(ArgumentError, "expected a source event")

  defp visual_identity(%SourceEvent{external_id: external_id}, _nonce)
       when is_binary(external_id),
       do: external_id

  defp visual_identity(%SourceEvent{source: :visitor}, nonce)
       when is_binary(nonce) and byte_size(nonce) > 0,
       do: nonce

  defp visual_identity(%SourceEvent{source: :visitor}, _nonce) do
    raise ArgumentError, "visitor visual parameters require a request nonce"
  end

  defp xorshift32(state) do
    first = band(bxor(state, bsl(state, 13)), @uint32_mask)
    second = band(bxor(first, bsr(first, 17)), @uint32_mask)
    band(bxor(second, bsl(second, 5)), @uint32_mask)
  end

  defp unit_float(state), do: state / @uint32_max
  defp rounded_unit_float(state), do: Float.round(unit_float(state), 6)
end
