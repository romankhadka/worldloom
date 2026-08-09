defmodule Worldloom.Loom.SourceEvent do
  @enforce_keys [:kind, :source, :external_id, :occurred_at, :lane, :intensity, :payload]
  @derive {Inspect, except: [:render_identity]}
  defstruct [
    :kind,
    :source,
    :external_id,
    :occurred_at,
    :lane,
    :intensity,
    :payload,
    :render_identity
  ]

  @type kind ::
          :wikimedia
          | :earthquake
          | :weather
          | :tug
          | :knot
          | :illuminate
          | :public_activity
          | :route_change
          | :slot
          | :randomness
  @type source ::
          :wikimedia | :usgs | :open_meteo | :visitor | :bluesky | :ripe_ris | :solana | :drand

  @type t :: %__MODULE__{
          kind: kind(),
          source: source(),
          external_id: String.t() | nil,
          occurred_at: DateTime.t(),
          lane: float(),
          intensity: float(),
          payload: map(),
          render_identity: String.t() | nil
        }

  @kinds [
    :wikimedia,
    :earthquake,
    :weather,
    :tug,
    :knot,
    :illuminate,
    :public_activity,
    :route_change,
    :slot,
    :randomness
  ]
  @sources [:wikimedia, :usgs, :open_meteo, :visitor, :bluesky, :ripe_ris, :solana, :drand]
  @kind_by_source %{
    wikimedia: [:wikimedia],
    usgs: [:earthquake],
    open_meteo: [:weather],
    visitor: [:tug, :knot, :illuminate],
    bluesky: [:public_activity],
    ripe_ris: [:route_change],
    solana: [:slot],
    drand: [:randomness]
  }
  @payload_keys %{
    wikimedia:
      ~w(summary window_count window_span_seconds count total_absolute_byte_delta languages language_buckets edit_types dominant_edit_type truncated),
    usgs: ~w(summary magnitude place coordinates additional_count places),
    open_meteo:
      ~w(summary temperature_range precipitation_coverage mean_wind day_night_ratio cities),
    visitor: ~w(summary),
    bluesky:
      ~w(summary window_count window_span_seconds total_actions original_posts replies reposts creates updates deletes truncated),
    ripe_ris:
      ~w(summary window_count window_span_seconds announced withdrawn ipv4 ipv6 collector_observations peer_observations truncated),
    solana:
      ~w(summary window_count window_span_seconds slot_count first_slot last_slot gap_count truncated),
    drand: ~w(summary round)
  }
  @exact_payload_sources [:bluesky, :ripe_ris, :solana, :drand]
  @wikimedia_pressure_keys ~w(summary window_count window_span_seconds count total_absolute_byte_delta language_buckets edit_types dominant_edit_type truncated)
  @wikimedia_language_buckets ~w(current_1 current_2 current_3 current_4 current_5)
  @wikimedia_edit_types ~w(categorize edit external log new)
  @json_safe_max 9_007_199_254_740_991
  @uint32_max 4_294_967_295

  @spec new(map()) :: {:ok, t()} | {:error, {atom(), atom()}}
  def new(attributes) when is_map(attributes) do
    with {:ok, kind} <- validate_kind(Map.get(attributes, :kind)),
         {:ok, source} <- validate_source(Map.get(attributes, :source)),
         :ok <- validate_pair(kind, source),
         {:ok, external_id} <- validate_external_id(Map.get(attributes, :external_id), source),
         {:ok, render_identity} <-
           validate_render_identity(Map.get(attributes, :render_identity), source),
         {:ok, occurred_at} <- normalize_occurred_at(Map.get(attributes, :occurred_at)),
         {:ok, lane} <- validate_unit_float(Map.get(attributes, :lane), :lane),
         {:ok, intensity} <-
           validate_unit_float(Map.get(attributes, :intensity), :intensity),
         {:ok, payload} <- validate_payload(Map.get(attributes, :payload), source) do
      {:ok,
       %__MODULE__{
         kind: kind,
         source: source,
         external_id: external_id,
         occurred_at: occurred_at,
         lane: lane,
         intensity: intensity,
         payload: payload,
         render_identity: render_identity
       }}
    end
  end

  def new(_attributes), do: {:error, {:event, :invalid}}

  @spec new!(map()) :: t()
  def new!(attributes) do
    case new(attributes) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, "invalid source event: #{inspect(reason)}"
    end
  end

  defp validate_kind(kind) when kind in @kinds, do: {:ok, kind}
  defp validate_kind(_kind), do: {:error, {:kind, :invalid}}

  defp validate_source(source) when source in @sources, do: {:ok, source}
  defp validate_source(_source), do: {:error, {:source, :invalid}}

  defp validate_pair(kind, source) do
    if kind in Map.fetch!(@kind_by_source, source) do
      :ok
    else
      {:error, {:kind, :source_mismatch}}
    end
  end

  defp validate_external_id(nil, :visitor), do: {:ok, nil}
  defp validate_external_id(nil, _source), do: {:error, {:external_id, :required}}

  defp validate_external_id(external_id, :visitor) when is_binary(external_id),
    do: {:error, {:external_id, :forbidden}}

  defp validate_external_id(external_id, _source)
       when is_binary(external_id) and byte_size(external_id) in 1..255,
       do: {:ok, external_id}

  defp validate_external_id(_external_id, _source), do: {:error, {:external_id, :invalid}}

  defp validate_render_identity(render_identity, :drand) when is_binary(render_identity) do
    if byte_size(render_identity) == 64 and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, render_identity) do
      {:ok, render_identity}
    else
      {:error, {:render_identity, :invalid}}
    end
  end

  defp validate_render_identity(nil, :drand), do: {:error, {:render_identity, :required}}
  defp validate_render_identity(nil, _source), do: {:ok, nil}

  defp validate_render_identity(_render_identity, _source),
    do: {:error, {:render_identity, :forbidden}}

  defp normalize_occurred_at(%DateTime{} = occurred_at) do
    case DateTime.shift_zone(occurred_at, "Etc/UTC") do
      {:ok, utc_occurred_at} -> {:ok, microsecond_precision(utc_occurred_at)}
      {:error, _reason} -> {:error, {:occurred_at, :invalid}}
    end
  end

  defp normalize_occurred_at(_occurred_at), do: {:error, {:occurred_at, :invalid}}

  defp microsecond_precision(%DateTime{microsecond: {microseconds, _precision}} = occurred_at) do
    %{occurred_at | microsecond: {microseconds, 6}}
  end

  defp validate_unit_float(number, field) when is_float(number) do
    if number >= 0.0 and number <= 1.0 do
      {:ok, number}
    else
      {:error, {field, :out_of_bounds}}
    end
  end

  defp validate_unit_float(_number, field), do: {:error, {field, :invalid}}

  defp validate_payload(payload, source) when is_map(payload) do
    allowed_keys = Map.fetch!(@payload_keys, source)
    keys = Map.keys(payload)

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        {:error, {:payload, :invalid_keys}}

      not Enum.all?(keys, &(&1 in allowed_keys)) ->
        {:error, {:payload, :invalid_keys}}

      source in @exact_payload_sources and Enum.sort(keys) != Enum.sort(allowed_keys) ->
        {:error, {:payload, :invalid_keys}}

      not is_binary(payload["summary"]) or String.trim(payload["summary"]) == "" ->
        {:error, {:payload, :summary_required}}

      String.length(payload["summary"]) > 160 ->
        {:error, {:payload, :summary_too_long}}

      validate_payload_shape(payload, source) == :error ->
        {:error, {:payload, :invalid_shape}}

      not json_payload_within_limit?(payload) ->
        {:error, {:payload, :invalid}}

      true ->
        {:ok, payload}
    end
  end

  defp validate_payload(_payload, _source), do: {:error, {:payload, :invalid}}

  defp json_payload_within_limit?(payload) do
    case Jason.encode(payload) do
      {:ok, encoded_payload} -> byte_size(encoded_payload) <= 16_384
      {:error, _reason} -> false
    end
  end

  defp validate_payload_shape(payload, :bluesky) do
    valid? =
      validate_window_payload(
        payload,
        ~w(total_actions original_posts replies reposts creates updates deletes)
      ) and boolean?(payload["truncated"]) and valid_bluesky_totals?(payload)

    boolean_result(valid?)
  end

  defp validate_payload_shape(payload, :ripe_ris) do
    valid? =
      validate_window_payload(
        payload,
        ~w(announced withdrawn ipv4 ipv6 collector_observations peer_observations)
      ) and boolean?(payload["truncated"]) and valid_ripe_totals?(payload) and
        valid_ripe_observations?(payload)

    boolean_result(valid?)
  end

  defp validate_payload_shape(payload, :solana) do
    common_valid? =
      validate_window_payload(payload, ~w(slot_count gap_count)) and
        json_safe_integer?(payload["first_slot"]) and
        json_safe_integer?(payload["last_slot"]) and
        payload["first_slot"] <= payload["last_slot"] and
        payload["slot_count"] > 0 and boolean?(payload["truncated"])

    valid? = common_valid? and valid_solana_summary?(payload)

    boolean_result(valid?)
  end

  defp validate_payload_shape(payload, :drand) do
    boolean_result(json_safe_integer?(payload["round"]) and payload["round"] > 0)
  end

  defp validate_payload_shape(payload, :wikimedia) do
    pressure_payload? =
      Enum.any?(~w(language_buckets edit_types truncated), &Map.has_key?(payload, &1))

    valid? =
      if pressure_payload? do
        Map.keys(payload) |> Enum.sort() == Enum.sort(@wikimedia_pressure_keys) and
          validate_window_payload(payload, ~w(count total_absolute_byte_delta)) and
          payload["count"] > 0 and boolean?(payload["truncated"]) and
          fixed_count_map?(payload["language_buckets"], @wikimedia_language_buckets) and
          fixed_count_map?(payload["edit_types"], @wikimedia_edit_types) and
          valid_wikimedia_totals?(payload) and
          payload["dominant_edit_type"] == dominant_key(payload["edit_types"])
      else
        optional_positive_uint32?(payload["count"]) and
          optional_uint32?(payload["total_absolute_byte_delta"]) and
          valid_optional_window?(payload["window_count"], payload["window_span_seconds"])
      end

    boolean_result(valid?)
  end

  defp validate_payload_shape(_payload, _source), do: :ok

  defp validate_window_payload(payload, counter_keys) do
    window_count = payload["window_count"]
    window_span_seconds = payload["window_span_seconds"]

    uint32?(window_count) and window_count > 0 and uint32?(window_span_seconds) and
      window_span_seconds == window_count * 4 and
      Enum.all?(counter_keys, &uint32?(payload[&1]))
  end

  defp valid_bluesky_totals?(payload) do
    operation_total = payload["creates"] + payload["updates"] + payload["deletes"]
    category_total = payload["original_posts"] + payload["replies"] + payload["reposts"]

    if payload["truncated"] and payload["total_actions"] == @uint32_max do
      operation_total >= @uint32_max
    else
      operation_total == payload["total_actions"] and category_total <= payload["total_actions"]
    end
  end

  defp valid_ripe_totals?(payload) do
    if payload["truncated"] do
      direction_range = possible_total_range(payload["announced"], payload["withdrawn"])
      family_range = possible_total_range(payload["ipv4"], payload["ipv6"])
      ranges_intersect?(direction_range, family_range)
    else
      payload["announced"] + payload["withdrawn"] == payload["ipv4"] + payload["ipv6"]
    end
  end

  defp valid_ripe_observations?(payload) do
    direction_total = payload["announced"] + payload["withdrawn"]
    family_total = payload["ipv4"] + payload["ipv6"]

    payload["collector_observations"] > 0 and payload["peer_observations"] > 0 and
      payload["collector_observations"] <= min(direction_total, family_total) and
      payload["peer_observations"] <= min(direction_total, family_total) and
      (payload["window_count"] > 1 or
         (payload["collector_observations"] in 1..4 and
            payload["peer_observations"] in 1..2_048))
  end

  defp valid_solana_summary?(payload) do
    payload["slot_count"] == 1 == (payload["first_slot"] == payload["last_slot"]) and
      payload["slot_count"] <= payload["last_slot"] - payload["first_slot"] + 1 and
      (not payload["truncated"] or payload["slot_count"] == @uint32_max or
         payload["gap_count"] == @uint32_max or
         payload["window_count"] == div(@uint32_max, 4))
  end

  defp fixed_count_map?(counts, keys) when is_map(counts) do
    Map.keys(counts) |> Enum.sort() == keys and
      Enum.all?(counts, fn {_key, count} -> uint32?(count) end)
  end

  defp fixed_count_map?(_counts, _keys), do: false

  defp valid_wikimedia_totals?(payload) do
    count = payload["count"]
    language_total = payload["language_buckets"] |> Map.values() |> Enum.sum()
    edit_type_total = payload["edit_types"] |> Map.values() |> Enum.sum()

    if payload["truncated"] and count == @uint32_max do
      language_total >= @uint32_max and edit_type_total >= @uint32_max
    else
      language_total == count and edit_type_total == count
    end
  end

  defp dominant_key(counts) do
    counts
    |> Enum.max_by(fn {key, count} -> {count, key} end)
    |> elem(0)
  end

  defp possible_total_range(first, second) when first == @uint32_max or second == @uint32_max,
    do: {:at_least, first + second}

  defp possible_total_range(first, second), do: {:exact, first + second}

  defp ranges_intersect?({:exact, first}, {:exact, second}), do: first == second
  defp ranges_intersect?({:exact, exact}, {:at_least, minimum}), do: exact >= minimum
  defp ranges_intersect?({:at_least, minimum}, {:exact, exact}), do: exact >= minimum
  defp ranges_intersect?({:at_least, _first}, {:at_least, _second}), do: true

  defp valid_optional_window?(nil, nil), do: true

  defp valid_optional_window?(window_count, window_span_seconds) do
    uint32?(window_count) and window_count > 0 and uint32?(window_span_seconds) and
      window_span_seconds == window_count * 4
  end

  defp optional_uint32?(nil), do: true
  defp optional_uint32?(number), do: uint32?(number)
  defp optional_positive_uint32?(nil), do: true
  defp optional_positive_uint32?(number), do: uint32?(number) and number > 0

  defp uint32?(number), do: is_integer(number) and number in 0..@uint32_max
  defp json_safe_integer?(number), do: is_integer(number) and number in 0..@json_safe_max
  defp boolean?(value), do: value in [true, false]
  defp boolean_result(true), do: :ok
  defp boolean_result(false), do: :error
end
