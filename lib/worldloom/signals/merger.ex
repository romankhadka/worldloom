defmodule Worldloom.Signals.Merger do
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Signals.Normalizer

  @identity_modulus Integer.pow(2, 256)
  @maximum_places 5
  @uint32_max 4_294_967_295
  @maximum_window_count div(@uint32_max, 4)
  @wikimedia_language_buckets ~w(current_1 current_2 current_3 current_4 current_5)
  @wikimedia_edit_types ~w(categorize edit external log new)
  @bluesky_counters ~w(total_actions original_posts replies reposts creates updates deletes)
  @ripe_counters ~w(announced withdrawn ipv4 ipv6 collector_observations peer_observations)
  @solana_counters ~w(slot_count gap_count)

  @spec merge([SourceEvent.t()]) :: {:ok, SourceEvent.t()} | {:error, atom()}
  def merge([%SourceEvent{} = event]), do: {:ok, event}

  def merge([%SourceEvent{} | _rest] = events) do
    case events |> Enum.map(& &1.source) |> Enum.uniq() do
      [:wikimedia] -> merge_wikimedia(events)
      [:usgs] -> merge_earthquakes(events)
      [:open_meteo] -> {:ok, Enum.max_by(events, & &1.occurred_at, DateTime)}
      [:bluesky] -> merge_bluesky(events)
      [:ripe_ris] -> merge_ripe(events)
      [:solana] -> merge_solana(events)
      [_source] -> {:error, :unsupported_source}
      _sources -> {:error, :mixed_sources}
    end
  end

  def merge(_events), do: {:error, :invalid_events}

  defp merge_wikimedia(events) do
    if Enum.all?(events, &wikimedia_pressure_event?/1) do
      merge_wikimedia_pressure(events)
    else
      {:error, :invalid_events}
    end
  end

  defp merge_wikimedia_pressure(events) do
    {window_count, window_overflow?} = merged_window_count(events)
    {count, count_overflow?} = saturated_sum(events, "count")
    {byte_delta, byte_overflow?} = saturated_sum(events, "total_absolute_byte_delta")

    {language_buckets, language_overflow?} =
      saturated_count_map(events, "language_buckets", @wikimedia_language_buckets)

    {edit_types, edit_type_overflow?} =
      saturated_count_map(events, "edit_types", @wikimedia_edit_types)

    truncated? =
      truncated_input?(events) or window_overflow? or count_overflow? or byte_overflow? or
        language_overflow? or edit_type_overflow?

    payload = %{
      "summary" =>
        pressure_summary(
          "#{count} Wikimedia edits",
          window_count,
          window_lower_bound?(events, window_overflow?)
        ),
      "window_count" => window_count,
      "window_span_seconds" => window_count * 4,
      "count" => count,
      "total_absolute_byte_delta" => byte_delta,
      "language_buckets" => language_buckets,
      "edit_types" => edit_types,
      "dominant_edit_type" => dominant_key(edit_types),
      "truncated" => truncated?
    }

    build_pressure_event(events, :wikimedia, :wikimedia, payload)
  end

  defp wikimedia_pressure_event?(event) do
    fixed_count_map?(event.payload["language_buckets"], @wikimedia_language_buckets) and
      fixed_count_map?(event.payload["edit_types"], @wikimedia_edit_types) and
      is_boolean(event.payload["truncated"])
  end

  defp fixed_count_map?(counts, keys) when is_map(counts) do
    Enum.sort(Map.keys(counts)) == keys and
      Enum.all?(counts, fn {_key, count} -> is_integer(count) and count in 0..@uint32_max end)
  end

  defp fixed_count_map?(_counts, _keys), do: false

  defp merge_bluesky(events) do
    {window_count, window_overflow?} = merged_window_count(events)
    {counters, counter_overflow?} = saturated_counters(events, @bluesky_counters)
    truncated? = truncated_input?(events) or window_overflow? or counter_overflow?

    payload =
      counters
      |> Map.merge(%{
        "summary" =>
          pressure_summary(
            "#{counters["total_actions"]} Bluesky actions",
            window_count,
            window_lower_bound?(events, window_overflow?)
          ),
        "window_count" => window_count,
        "window_span_seconds" => window_count * 4,
        "truncated" => truncated?
      })

    build_pressure_event(events, :public_activity, :bluesky, payload)
  end

  defp merge_ripe(events) do
    {window_count, window_overflow?} = merged_window_count(events)
    {counters, counter_overflow?} = saturated_counters(events, @ripe_counters)
    route_changes = counters["announced"] + counters["withdrawn"]
    truncated? = truncated_input?(events) or window_overflow? or counter_overflow?

    payload =
      counters
      |> Map.merge(%{
        "summary" =>
          pressure_summary(
            "#{route_changes} RIPE route changes",
            window_count,
            window_lower_bound?(events, window_overflow?)
          ),
        "window_count" => window_count,
        "window_span_seconds" => window_count * 4,
        "truncated" => truncated?
      })

    build_pressure_event(events, :route_change, :ripe_ris, payload)
  end

  defp merge_solana(events) do
    {window_count, window_overflow?} = merged_window_count(events)
    {counters, counter_overflow?} = saturated_counters(events, @solana_counters)
    truncated? = truncated_input?(events) or window_overflow? or counter_overflow?

    first_slot = events |> Enum.map(&payload_integer(&1, "first_slot", 0)) |> Enum.min()
    last_slot = events |> Enum.map(&payload_integer(&1, "last_slot", 0)) |> Enum.max()

    payload =
      counters
      |> Map.merge(%{
        "summary" =>
          pressure_summary(
            "#{counters["slot_count"]} Solana slots with #{counters["gap_count"]} gaps",
            window_count,
            window_lower_bound?(events, window_overflow?)
          ),
        "window_count" => window_count,
        "window_span_seconds" => window_count * 4,
        "first_slot" => first_slot,
        "last_slot" => last_slot,
        "truncated" => truncated?
      })

    build_pressure_event(events, :slot, :solana, payload)
  end

  defp build_pressure_event(events, kind, source, payload) do
    with {:ok, visual} <- Normalizer.derive_lane_and_intensity(source, payload),
         {:ok, event} <-
           SourceEvent.new(%{
             kind: kind,
             source: source,
             external_id: merged_external_id(events),
             occurred_at: latest_occurred_at(events),
             lane: visual.lane,
             intensity: visual.intensity,
             payload: payload
           }) do
      {:ok, event}
    else
      _invalid -> {:error, :invalid_events}
    end
  end

  defp merge_earthquakes(events) do
    strongest =
      Enum.max_by(events, fn event ->
        {payload_number(event, "magnitude", 0.0), event.occurred_at, event.external_id}
      end)

    total_count =
      Enum.sum(Enum.map(events, &(payload_integer(&1, "additional_count", 0) + 1)))

    places =
      events
      |> Enum.sort_by(fn event ->
        {-payload_number(event, "magnitude", 0.0), event.external_id}
      end)
      |> Enum.flat_map(fn event ->
        [Map.get(event.payload, "place") | Map.get(event.payload, "places", [])]
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.take(@maximum_places)

    magnitude = payload_number(strongest, "magnitude", 0.0)
    place = Map.get(strongest.payload, "place", "an unspecified region")
    additional_count = total_count - 1

    summary =
      if additional_count > 0 do
        "Magnitude #{magnitude} near #{place}, plus #{additional_count} more"
      else
        "Magnitude #{magnitude} near #{place}"
      end

    attributes = %{
      kind: :earthquake,
      source: :usgs,
      external_id: merged_external_id(events),
      occurred_at: latest_occurred_at(events),
      lane: strongest.lane,
      intensity: Enum.max(Enum.map(events, & &1.intensity)),
      payload:
        strongest.payload
        |> Map.take(~w(magnitude place coordinates))
        |> Map.merge(%{
          "summary" => truncate_summary(summary),
          "additional_count" => additional_count,
          "places" => places
        })
    }

    SourceEvent.new(attributes)
  end

  defp merged_window_count(events) do
    Enum.reduce(events, {0, false}, fn event, {total, overflow?} ->
      {next_total, next_overflow?} =
        saturated_add(total, payload_integer(event, "window_count", 1), @maximum_window_count)

      {next_total, overflow? or next_overflow?}
    end)
  end

  defp saturated_counters(events, keys) do
    Enum.reduce(keys, {%{}, false}, fn key, {counters, overflow?} ->
      {count, count_overflow?} = saturated_sum(events, key)
      {Map.put(counters, key, count), overflow? or count_overflow?}
    end)
  end

  defp saturated_count_map(events, payload_key, keys) do
    Enum.reduce(keys, {%{}, false}, fn key, {counts, overflow?} ->
      {count, count_overflow?} =
        Enum.reduce(events, {0, false}, fn event, {total, event_overflow?} ->
          event_count = event.payload |> Map.fetch!(payload_key) |> Map.fetch!(key)
          {next_total, next_overflow?} = saturated_add(total, event_count, @uint32_max)
          {next_total, event_overflow? or next_overflow?}
        end)

      {Map.put(counts, key, count), overflow? or count_overflow?}
    end)
  end

  defp saturated_sum(events, key) do
    Enum.reduce(events, {0, false}, fn event, {total, overflow?} ->
      {next_total, next_overflow?} =
        saturated_add(total, payload_integer(event, key, 0), @uint32_max)

      {next_total, overflow? or next_overflow?}
    end)
  end

  defp saturated_add(left, right, maximum) do
    sum = left + right
    {min(sum, maximum), sum > maximum}
  end

  defp truncated_input?(events),
    do: Enum.any?(events, &(Map.get(&1.payload, "truncated", false) == true))

  defp pressure_summary(subject, window_count, lower_bound?) do
    {window_prefix, span_prefix} = if lower_bound?, do: {"at least ", "at least "}, else: {"", ""}

    truncate_summary(
      "Pressure summary: #{subject} across #{window_prefix}#{window_count} windows (#{span_prefix}#{window_count * 4} seconds)"
    )
  end

  defp window_lower_bound?(events, overflow?) do
    overflow? or
      Enum.any?(events, fn event ->
        payload_integer(event, "window_count", 1) == @maximum_window_count and
          Map.get(event.payload, "truncated", false) == true
      end)
  end

  defp dominant_key(counts) do
    counts
    |> Enum.max_by(fn {key, count} -> {count, key} end)
    |> elem(0)
  end

  defp merged_external_id(events) do
    accumulator =
      Enum.reduce(events, 0, fn event, checksum ->
        rem(checksum + identity_checksum(event.external_id), @identity_modulus)
      end)

    "merged:" <> (accumulator |> Integer.to_string(16) |> String.pad_leading(64, "0"))
  end

  defp identity_checksum("merged:" <> encoded_checksum) do
    case {byte_size(encoded_checksum), Integer.parse(encoded_checksum, 16)} do
      {64, {checksum, ""}} -> checksum
      _invalid -> hash_identity("merged:" <> encoded_checksum)
    end
  end

  defp identity_checksum(external_id), do: hash_identity(external_id)

  defp hash_identity(external_id) do
    :sha256
    |> :crypto.hash(external_id)
    |> :binary.decode_unsigned()
  end

  defp latest_occurred_at(events),
    do: events |> Enum.max_by(& &1.occurred_at, DateTime) |> Map.fetch!(:occurred_at)

  defp payload_integer(event, key, default) do
    case Map.get(event.payload, key, default) do
      number when is_integer(number) -> number
      _invalid -> default
    end
  end

  defp payload_number(event, key, default) do
    case Map.get(event.payload, key, default) do
      number when is_number(number) -> number
      _invalid -> default
    end
  end

  defp truncate_summary(summary),
    do: summary |> String.graphemes() |> Enum.take(160) |> Enum.join()
end
