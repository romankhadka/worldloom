defmodule Worldloom.Signals.Normalizer do
  alias Worldloom.Loom.SourceEvent

  @json_safe_max 9_007_199_254_740_991
  @maximum_languages 5
  @uint32_max 4_294_967_295

  @spec wikimedia_bucket(map()) :: {:ok, SourceEvent.t()} | {:error, atom()}
  def wikimedia_bucket(%{
        window_start: %DateTime{} = window_start,
        count: count,
        total_absolute_byte_delta: total_absolute_byte_delta,
        languages: languages,
        edit_types: edit_types
      })
      when is_integer(count) and count > 0 and is_integer(total_absolute_byte_delta) and
             total_absolute_byte_delta >= 0 and is_map(languages) and is_map(edit_types) do
    with {:ok, utc_window_start} <- DateTime.shift_zone(window_start, "Etc/UTC"),
         {:ok, public_languages} <- normalize_count_map(languages, @maximum_languages),
         {:ok, public_edit_types} <- normalize_count_map(edit_types, map_size(edit_types)) do
      dominant_edit_type = dominant_key(public_edit_types, "edit")
      language_count = map_size(public_languages)

      SourceEvent.new(%{
        kind: :wikimedia,
        source: :wikimedia,
        external_id: "wikimedia-window:#{DateTime.to_unix(utc_window_start, :second)}:4",
        occurred_at: utc_window_start,
        lane: stable_lane(public_languages),
        intensity: clamp_unit(count / 20 + min(total_absolute_byte_delta / 50_000, 0.5)),
        payload: %{
          "summary" => "#{count} edits moved through #{language_count} languages",
          "window_count" => 1,
          "window_span_seconds" => 4,
          "count" => count,
          "total_absolute_byte_delta" => total_absolute_byte_delta,
          "languages" => public_languages,
          "dominant_edit_type" => dominant_edit_type
        }
      })
    else
      _invalid -> {:error, :invalid_bucket}
    end
  end

  def wikimedia_bucket(_bucket), do: {:error, :invalid_bucket}

  @spec bluesky_window(map()) :: {:ok, SourceEvent.t()} | {:error, atom()}
  def bluesky_window(%{
        window_start: %DateTime{} = window_start,
        total_actions: total_actions,
        original_posts: original_posts,
        replies: replies,
        reposts: reposts,
        creates: creates,
        updates: updates,
        deletes: deletes,
        truncated: truncated
      }) do
    counters = %{
      total_actions: total_actions,
      original_posts: original_posts,
      replies: replies,
      reposts: reposts,
      creates: creates,
      updates: updates,
      deletes: deletes
    }

    with true <- Enum.all?(counters, fn {_name, count} -> uint32?(count) end),
         true <- total_actions > 0,
         true <- is_boolean(truncated),
         true <- valid_bluesky_totals?(counters, truncated),
         {:ok, utc_window_start} <- DateTime.shift_zone(window_start, "Etc/UTC"),
         {:ok, event} <-
           SourceEvent.new(%{
             kind: :public_activity,
             source: :bluesky,
             external_id: "bluesky-window:#{DateTime.to_unix(utc_window_start, :second)}:4",
             occurred_at: utc_window_start,
             lane: stable_lane(counters),
             intensity: clamp_unit(total_actions / 40),
             payload: %{
               "summary" => "#{total_actions} public Bluesky actions moved through the weave",
               "window_count" => 1,
               "window_span_seconds" => 4,
               "total_actions" => total_actions,
               "original_posts" => original_posts,
               "replies" => replies,
               "reposts" => reposts,
               "creates" => creates,
               "updates" => updates,
               "deletes" => deletes,
               "truncated" => truncated
             }
           }) do
      {:ok, event}
    else
      _invalid -> {:error, :invalid_window}
    end
  end

  def bluesky_window(_window), do: {:error, :invalid_window}

  @spec ripe_window(map()) :: {:ok, SourceEvent.t()} | {:error, atom()}
  def ripe_window(%{
        window_start: %DateTime{} = window_start,
        announced: announced,
        withdrawn: withdrawn,
        ipv4: ipv4,
        ipv6: ipv6,
        collector_count: collector_count,
        peer_count: peer_count,
        truncated: truncated
      }) do
    counters = %{
      announced: announced,
      withdrawn: withdrawn,
      ipv4: ipv4,
      ipv6: ipv6,
      collector_count: collector_count,
      peer_count: peer_count
    }

    with true <- Enum.all?(counters, fn {_name, count} -> uint32?(count) end),
         {prefix_total, family_total} <- ripe_totals(counters),
         true <- collector_count in 1..4,
         true <- peer_count in 1..2_048,
         true <- prefix_total > 0,
         true <- family_total > 0,
         true <- is_boolean(truncated),
         true <- distinct_counts_fit?(collector_count, peer_count, prefix_total, family_total),
         true <- valid_ripe_totals?(counters, truncated),
         {:ok, utc_window_start} <- DateTime.shift_zone(window_start, "Etc/UTC"),
         {:ok, event} <-
           SourceEvent.new(%{
             kind: :route_change,
             source: :ripe_ris,
             external_id: "ripe-window:#{DateTime.to_unix(utc_window_start, :second)}:4",
             occurred_at: utc_window_start,
             lane: stable_lane(counters),
             intensity: clamp_unit(prefix_total / 80),
             payload: %{
               "summary" => "#{prefix_total} RIPE route changes moved through the weave",
               "window_count" => 1,
               "window_span_seconds" => 4,
               "announced" => announced,
               "withdrawn" => withdrawn,
               "ipv4" => ipv4,
               "ipv6" => ipv6,
               "collector_count" => collector_count,
               "peer_count" => peer_count,
               "truncated" => truncated
             }
           }) do
      {:ok, event}
    else
      _invalid -> {:error, :invalid_window}
    end
  end

  def ripe_window(_window), do: {:error, :invalid_window}

  @spec solana_window(map()) :: {:ok, SourceEvent.t()} | {:error, atom()}
  def solana_window(
        %{
          window_start: %DateTime{} = window_start,
          slot_count: slot_count,
          first_slot: first_slot,
          last_slot: last_slot,
          gap_count: gap_count,
          truncated: truncated
        } = window
      ) do
    continuity_anchor = Map.get(window, :continuity_anchor)

    approved_metrics = %{
      slot_count: slot_count,
      first_slot: first_slot,
      last_slot: last_slot,
      gap_count: gap_count
    }

    with true <- uint32?(slot_count),
         true <- slot_count > 0,
         true <- uint32?(gap_count),
         true <- json_safe_integer?(first_slot),
         true <- json_safe_integer?(last_slot),
         true <- first_slot <= last_slot,
         true <- slot_count <= last_slot - first_slot + 1,
         true <- is_boolean(truncated),
         true <- valid_continuity_anchor?(continuity_anchor, first_slot),
         true <- valid_solana_truncation?(slot_count, gap_count, truncated),
         logical_span <- solana_logical_span(continuity_anchor, first_slot, last_slot),
         true <- possible_solana_total_includes?(slot_count, gap_count, truncated, logical_span),
         {:ok, utc_window_start} <- DateTime.shift_zone(window_start, "Etc/UTC"),
         {:ok, event} <-
           SourceEvent.new(%{
             kind: :slot,
             source: :solana,
             external_id: "solana-window:#{DateTime.to_unix(utc_window_start, :second)}:4",
             occurred_at: utc_window_start,
             lane: stable_lane(approved_metrics),
             intensity: clamp_unit(slot_count / 40 + min(gap_count / 40, 0.5)),
             payload: %{
               "summary" => "#{slot_count} Solana slots advanced with #{gap_count} gaps",
               "window_count" => 1,
               "window_span_seconds" => 4,
               "slot_count" => slot_count,
               "first_slot" => first_slot,
               "last_slot" => last_slot,
               "gap_count" => gap_count,
               "truncated" => truncated
             }
           }) do
      {:ok, event}
    else
      _invalid -> {:error, :invalid_window}
    end
  end

  def solana_window(_window), do: {:error, :invalid_window}

  @spec earthquakes(map()) :: {:ok, [SourceEvent.t()]} | {:error, atom()}
  def earthquakes(%{"features" => features}) when is_list(features) do
    events = Enum.flat_map(features, &normalize_earthquake/1)
    {:ok, events}
  end

  def earthquakes(_geojson), do: {:error, :invalid_geojson}

  @spec weather([map()], [String.t() | map()]) ::
          {:ok, SourceEvent.t()} | {:error, atom()}
  def weather(responses, anchors)
      when is_list(responses) and is_list(anchors) and responses != [] and
             length(responses) == length(anchors) do
    with {:ok, labels} <- normalize_anchor_labels(anchors),
         {:ok, observations} <- normalize_weather_observations(responses) do
      temperatures = Enum.map(observations, & &1.temperature)
      precipitation_count = Enum.count(observations, &(&1.precipitation > 0.0))
      winds = Enum.map(observations, & &1.wind)
      day_count = Enum.count(observations, &(&1.is_day == 1))
      observation_count = length(observations)
      minimum_temperature = Enum.min(temperatures)
      maximum_temperature = Enum.max(temperatures)
      mean_temperature = Enum.sum(temperatures) / observation_count
      precipitation_coverage = round_six(precipitation_count / observation_count)
      mean_wind = round_six(Enum.sum(winds) / observation_count)
      day_night_ratio = round_six(day_count / observation_count)

      occurred_at =
        observations |> Enum.max_by(& &1.occurred_at, DateTime) |> Map.fetch!(:occurred_at)

      SourceEvent.new(%{
        kind: :weather,
        source: :open_meteo,
        external_id: "weather:#{DateTime.to_iso8601(occurred_at)}",
        occurred_at: occurred_at,
        lane: clamp_unit((mean_temperature + 30.0) / 80.0),
        intensity: clamp_unit(mean_wind / 80.0 * 0.6 + precipitation_coverage * 0.4),
        payload: %{
          "summary" =>
            truncate_summary(
              "#{observation_count} cities span #{minimum_temperature}–#{maximum_temperature}°C"
            ),
          "temperature_range" => [minimum_temperature, maximum_temperature],
          "precipitation_coverage" => precipitation_coverage,
          "mean_wind" => mean_wind,
          "day_night_ratio" => day_night_ratio,
          "cities" => labels
        }
      })
    else
      _invalid -> {:error, :invalid_weather}
    end
  end

  def weather(_responses, _anchors), do: {:error, :invalid_weather}

  defp normalize_earthquake(%{
         "id" => external_id,
         "properties" => %{"mag" => magnitude, "place" => place, "time" => unix_milliseconds},
         "geometry" => %{"coordinates" => [longitude, latitude | _rest] = coordinates}
       })
       when is_binary(external_id) and byte_size(external_id) in 1..255 and
              is_number(magnitude) and is_binary(place) and is_integer(unix_milliseconds) and
              is_number(longitude) and is_number(latitude) do
    with {:ok, occurred_at} <- DateTime.from_unix(unix_milliseconds, :millisecond),
         public_place when public_place != "" <- place |> String.trim() |> truncate(100),
         public_coordinates when is_list(public_coordinates) <- normalize_coordinates(coordinates),
         public_magnitude <- magnitude |> to_float() |> clamp(0.0, 10.0),
         {:ok, event} <-
           SourceEvent.new(%{
             kind: :earthquake,
             source: :usgs,
             external_id: external_id,
             occurred_at: occurred_at,
             lane: clamp_unit((90.0 - to_float(latitude)) / 180.0),
             intensity: clamp_unit(public_magnitude / 10.0),
             payload: %{
               "summary" =>
                 truncate_summary(
                   "Magnitude #{format_decimal(public_magnitude)} near #{public_place}"
                 ),
               "magnitude" => public_magnitude,
               "place" => public_place,
               "coordinates" => public_coordinates
             }
           }) do
      [event]
    else
      _invalid -> []
    end
  end

  defp normalize_earthquake(_feature), do: []

  defp normalize_coordinates(coordinates) do
    coordinates
    |> Enum.take(3)
    |> Enum.reduce_while([], fn
      coordinate, normalized when is_number(coordinate) ->
        {:cont, [to_float(coordinate) | normalized]}

      _coordinate, _normalized ->
        {:halt, :invalid}
    end)
    |> case do
      :invalid -> :invalid
      normalized -> Enum.reverse(normalized)
    end
  end

  defp normalize_anchor_labels(anchors) do
    Enum.reduce_while(anchors, {:ok, []}, fn anchor, {:ok, labels} ->
      case anchor_label(anchor) do
        label when is_binary(label) and byte_size(label) in 1..80 ->
          {:cont, {:ok, [label | labels]}}

        _invalid ->
          {:halt, {:error, :invalid_anchor}}
      end
    end)
    |> case do
      {:ok, labels} -> {:ok, Enum.reverse(labels)}
      error -> error
    end
  end

  defp anchor_label(label) when is_binary(label), do: label
  defp anchor_label(%{label: label}) when is_binary(label), do: label
  defp anchor_label(%{"label" => label}) when is_binary(label), do: label
  defp anchor_label(_anchor), do: nil

  defp normalize_weather_observations(responses) do
    Enum.reduce_while(responses, {:ok, []}, fn response, {:ok, observations} ->
      case weather_observation(response) do
        {:ok, observation} -> {:cont, {:ok, [observation | observations]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, observations} -> {:ok, Enum.reverse(observations)}
      error -> error
    end
  end

  defp weather_observation(%{
         "current" => %{
           "time" => encoded_time,
           "temperature_2m" => temperature,
           "precipitation" => precipitation,
           "wind_speed_10m" => wind,
           "is_day" => is_day
         }
       })
       when is_binary(encoded_time) and is_number(temperature) and is_number(precipitation) and
              precipitation >= 0 and is_number(wind) and wind >= 0 and is_day in [0, 1] do
    case parse_utc_datetime(encoded_time) do
      {:ok, occurred_at} ->
        {:ok,
         %{
           occurred_at: occurred_at,
           temperature: to_float(temperature),
           precipitation: to_float(precipitation),
           wind: to_float(wind),
           is_day: is_day
         }}

      {:error, _reason} ->
        {:error, :invalid_time}
    end
  end

  defp weather_observation(_response), do: {:error, :invalid_observation}

  defp parse_utc_datetime(encoded_time) do
    encoded_time = normalize_minute_precision(encoded_time)

    case DateTime.from_iso8601(encoded_time) do
      {:ok, occurred_at, _offset} ->
        DateTime.shift_zone(occurred_at, "Etc/UTC")

      {:error, _reason} ->
        with {:ok, naive_time} <- NaiveDateTime.from_iso8601(encoded_time),
             {:ok, occurred_at} <- DateTime.from_naive(naive_time, "Etc/UTC") do
          {:ok, occurred_at}
        end
    end
  end

  defp normalize_minute_precision(
         <<date::binary-size(10), "T", hour::binary-size(2), ":", minute::binary-size(2)>>
       ),
       do: date <> "T" <> hour <> ":" <> minute <> ":00"

  defp normalize_minute_precision(encoded_time), do: encoded_time

  defp normalize_count_map(counts, maximum_size) when maximum_size >= 0 do
    counts
    |> Enum.reduce_while([], fn
      {key, count}, normalized when is_binary(key) and is_integer(count) and count >= 0 ->
        {:cont, [{key, count} | normalized]}

      _entry, _normalized ->
        {:halt, :invalid}
    end)
    |> case do
      :invalid ->
        {:error, :invalid_counts}

      normalized ->
        public_counts =
          normalized
          |> Enum.sort_by(fn {key, count} -> {-count, key} end)
          |> Enum.take(maximum_size)
          |> Map.new()

        {:ok, public_counts}
    end
  end

  defp dominant_key(counts, default) when map_size(counts) == 0, do: default

  defp dominant_key(counts, _default) do
    counts
    |> Enum.max_by(fn {key, count} -> {count, key} end)
    |> elem(0)
  end

  defp stable_lane(public_shape), do: :erlang.phash2(public_shape, 10_001) / 10_000

  defp valid_bluesky_totals?(counters, false) do
    operation_total = counters.creates + counters.updates + counters.deletes
    category_total = counters.original_posts + counters.replies + counters.reposts

    operation_total == counters.total_actions and category_total <= counters.total_actions
  end

  defp valid_bluesky_totals?(counters, true) do
    operation_total = counters.creates + counters.updates + counters.deletes

    counters.total_actions == 4_294_967_295 and
      operation_total >= counters.total_actions and
      counters
      |> Map.delete(:total_actions)
      |> Enum.all?(fn {_name, count} -> count <= counters.total_actions end)
  end

  defp ripe_totals(counters) do
    {counters.announced + counters.withdrawn, counters.ipv4 + counters.ipv6}
  end

  defp distinct_counts_fit?(collector_count, peer_count, prefix_total, family_total) do
    collector_count <= prefix_total and collector_count <= family_total and
      peer_count <= prefix_total and peer_count <= family_total
  end

  defp valid_ripe_totals?(counters, false) do
    {prefix_total, family_total} = ripe_totals(counters)
    prefix_total == family_total
  end

  defp valid_ripe_totals?(counters, true) do
    direction_range = possible_total_range(counters.announced, counters.withdrawn)
    family_range = possible_total_range(counters.ipv4, counters.ipv6)
    ranges_intersect?(direction_range, family_range)
  end

  defp possible_total_range(first, second) when first == @uint32_max or second == @uint32_max,
    do: {:at_least, first + second}

  defp possible_total_range(first, second), do: {:exact, first + second}

  defp ranges_intersect?({:exact, first}, {:exact, second}), do: first == second
  defp ranges_intersect?({:exact, exact}, {:at_least, minimum}), do: exact >= minimum
  defp ranges_intersect?({:at_least, minimum}, {:exact, exact}), do: exact >= minimum
  defp ranges_intersect?({:at_least, _first}, {:at_least, _second}), do: true

  defp valid_continuity_anchor?(nil, _first_slot), do: true

  defp valid_continuity_anchor?(continuity_anchor, first_slot),
    do: json_safe_integer?(continuity_anchor) and continuity_anchor < first_slot

  defp valid_solana_truncation?(_slot_count, _gap_count, false), do: true

  defp valid_solana_truncation?(slot_count, gap_count, true),
    do: slot_count == @uint32_max or gap_count == @uint32_max

  defp solana_logical_span(nil, first_slot, last_slot), do: last_slot - first_slot + 1

  defp solana_logical_span(continuity_anchor, _first_slot, last_slot),
    do: last_slot - continuity_anchor

  defp possible_solana_total_includes?(slot_count, gap_count, true, logical_span)
       when slot_count == @uint32_max or gap_count == @uint32_max,
       do: slot_count + gap_count <= logical_span

  defp possible_solana_total_includes?(slot_count, gap_count, _truncated, logical_span),
    do: slot_count + gap_count == logical_span

  defp uint32?(number), do: is_integer(number) and number in 0..@uint32_max
  defp json_safe_integer?(number), do: is_integer(number) and number in 0..@json_safe_max
  defp format_decimal(number), do: :erlang.float_to_binary(number, decimals: 1)
  defp to_float(number) when is_float(number), do: number
  defp to_float(number) when is_integer(number), do: number * 1.0
  defp round_six(number), do: Float.round(number, 6)
  defp clamp_unit(number), do: clamp(number, 0.0, 1.0)
  defp clamp(number, minimum, maximum), do: number |> max(minimum) |> min(maximum)
  defp truncate_summary(summary), do: truncate(summary, 160)

  defp truncate(string, length),
    do: string |> String.graphemes() |> Enum.take(length) |> Enum.join()
end
