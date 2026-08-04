defmodule Worldloom.Signals.Merger do
  alias Worldloom.Loom.SourceEvent

  @identity_modulus Integer.pow(2, 256)
  @maximum_places 5
  @maximum_languages 5

  @spec merge([SourceEvent.t()]) :: {:ok, SourceEvent.t()} | {:error, atom()}
  def merge([%SourceEvent{} = event]), do: {:ok, event}

  def merge([%SourceEvent{} | _rest] = events) do
    case events |> Enum.map(& &1.source) |> Enum.uniq() do
      [:wikimedia] -> merge_wikimedia(events)
      [:usgs] -> merge_earthquakes(events)
      [:open_meteo] -> {:ok, Enum.max_by(events, & &1.occurred_at, DateTime)}
      [_source] -> {:error, :unsupported_source}
      _sources -> {:error, :mixed_sources}
    end
  end

  def merge(_events), do: {:error, :invalid_events}

  defp merge_wikimedia(events) do
    count = Enum.sum(Enum.map(events, &payload_integer(&1, "count", 1)))

    languages =
      events
      |> Enum.flat_map(fn event -> Map.to_list(Map.get(event.payload, "languages", %{})) end)
      |> Enum.reduce(%{}, fn {language, language_count}, totals ->
        Map.update(totals, language, language_count, &(&1 + language_count))
      end)
      |> Enum.sort_by(fn {language, language_count} -> {-language_count, language} end)
      |> Enum.take(@maximum_languages)
      |> Map.new()

    dominant_edit_type =
      events
      |> Enum.group_by(&Map.get(&1.payload, "dominant_edit_type", "edit"))
      |> Enum.map(fn {edit_type, grouped_events} ->
        weighted_count = Enum.sum(Enum.map(grouped_events, &payload_integer(&1, "count", 1)))
        {edit_type, weighted_count}
      end)
      |> Enum.max_by(fn {edit_type, weighted_count} -> {weighted_count, edit_type} end)
      |> elem(0)

    weighted_lane =
      events
      |> Enum.map(fn event -> event.lane * payload_integer(event, "count", 1) end)
      |> Enum.sum()
      |> Kernel./(count)
      |> clamp_unit()

    attributes = %{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: merged_external_id(events),
      occurred_at: latest_occurred_at(events),
      lane: weighted_lane,
      intensity: events |> Enum.map(& &1.intensity) |> Enum.sum() |> clamp_unit(),
      payload: %{
        "summary" => "#{count} edits moved through #{map_size(languages)} languages",
        "count" => count,
        "total_absolute_byte_delta" =>
          Enum.sum(Enum.map(events, &payload_integer(&1, "total_absolute_byte_delta", 0))),
        "languages" => languages,
        "dominant_edit_type" => dominant_edit_type
      }
    }

    SourceEvent.new(attributes)
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

  defp clamp_unit(number), do: number |> max(0.0) |> min(1.0)
end
