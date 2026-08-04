defmodule Worldloom.Loom.SourceEvent do
  @enforce_keys [:kind, :source, :external_id, :occurred_at, :lane, :intensity, :payload]
  defstruct [:kind, :source, :external_id, :occurred_at, :lane, :intensity, :payload]

  @type kind :: :wikimedia | :earthquake | :weather | :tug | :knot | :illuminate
  @type source :: :wikimedia | :usgs | :open_meteo | :visitor

  @type t :: %__MODULE__{
          kind: kind(),
          source: source(),
          external_id: String.t() | nil,
          occurred_at: DateTime.t(),
          lane: float(),
          intensity: float(),
          payload: map()
        }

  @kinds [:wikimedia, :earthquake, :weather, :tug, :knot, :illuminate]
  @sources [:wikimedia, :usgs, :open_meteo, :visitor]
  @kind_by_source %{
    wikimedia: [:wikimedia],
    usgs: [:earthquake],
    open_meteo: [:weather],
    visitor: [:tug, :knot, :illuminate]
  }
  @payload_keys %{
    wikimedia: ~w(summary count total_absolute_byte_delta languages dominant_edit_type),
    usgs: ~w(summary magnitude place coordinates additional_count places),
    open_meteo:
      ~w(summary temperature_range precipitation_coverage mean_wind day_night_ratio cities),
    visitor: ~w(summary)
  }

  @spec new(map()) :: {:ok, t()} | {:error, {atom(), atom()}}
  def new(attributes) when is_map(attributes) do
    with {:ok, kind} <- validate_kind(Map.get(attributes, :kind)),
         {:ok, source} <- validate_source(Map.get(attributes, :source)),
         :ok <- validate_pair(kind, source),
         {:ok, external_id} <- validate_external_id(Map.get(attributes, :external_id), source),
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
         payload: payload
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

      not is_binary(payload["summary"]) or String.trim(payload["summary"]) == "" ->
        {:error, {:payload, :summary_required}}

      String.length(payload["summary"]) > 160 ->
        {:error, {:payload, :summary_too_long}}

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
end
