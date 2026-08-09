defmodule Worldloom.Loom.InstructionMetrics do
  @json_safe_max 9_007_199_254_740_991
  @uint32_max 4_294_967_295

  @metric_keys %{
    "bluesky" =>
      ~w(window_count window_span_seconds total_actions original_posts replies reposts creates updates deletes truncated),
    "ripe_ris" =>
      ~w(window_count window_span_seconds announced withdrawn ipv4 ipv6 collector_count peer_count truncated),
    "solana" =>
      ~w(window_count window_span_seconds slot_count first_slot last_slot gap_count truncated),
    "drand" => ~w(round)
  }

  @boolean_keys ~w(truncated)

  @spec from_payload(String.t(), map()) :: map() | :error
  def from_payload(source, payload) when is_binary(source) and is_map(payload) do
    with {:ok, allowed_keys} <- Map.fetch(@metric_keys, source),
         {:ok, metrics} <- rebuild_metrics(payload, allowed_keys),
         :ok <- validate_metrics(source, metrics) do
      metrics
    else
      _reason -> :error
    end
  end

  def from_payload(_source, _payload), do: :error

  defp rebuild_metrics(payload, allowed_keys) do
    Enum.reduce_while(allowed_keys, {:ok, %{}}, fn key, {:ok, metrics} ->
      case Map.fetch(payload, key) do
        {:ok, metric} ->
          if valid_scalar?(key, metric) do
            {:cont, {:ok, Map.put(metrics, key, metric)}}
          else
            {:halt, :error}
          end

        :error ->
          {:halt, :error}
      end
    end)
  end

  defp valid_scalar?(key, metric) when key in @boolean_keys, do: is_boolean(metric)

  defp valid_scalar?(key, metric) when key in ~w(first_slot last_slot),
    do: json_safe_integer?(metric)

  defp valid_scalar?(_key, metric), do: uint32?(metric)

  defp validate_metrics("bluesky", metrics), do: validate_window(metrics)
  defp validate_metrics("ripe_ris", metrics), do: validate_window(metrics)

  defp validate_metrics("solana", metrics) do
    with :ok <- validate_window(metrics),
         true <- metrics["first_slot"] <= metrics["last_slot"],
         true <- metrics["slot_count"] > 0,
         true <- metrics["slot_count"] <= metrics["last_slot"] - metrics["first_slot"] + 1,
         true <-
           not metrics["truncated"] or metrics["slot_count"] == @uint32_max or
             metrics["gap_count"] == @uint32_max do
      :ok
    else
      _reason -> :error
    end
  end

  defp validate_metrics("drand", %{"round" => round}) when round > 0, do: :ok
  defp validate_metrics(_source, _metrics), do: :error

  defp validate_window(metrics) do
    window_count = metrics["window_count"]
    window_span_seconds = metrics["window_span_seconds"]

    if window_count > 0 and window_span_seconds == window_count * 4 do
      :ok
    else
      :error
    end
  end

  defp uint32?(number), do: is_integer(number) and number in 0..@uint32_max
  defp json_safe_integer?(number), do: is_integer(number) and number in 0..@json_safe_max
end
