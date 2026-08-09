defmodule Worldloom.Signals.Config do
  @moduledoc false

  alias Worldloom.Signals.DrandClient

  @derive {Inspect,
           only: [
             :enabled,
             :earthquake_interval_ms,
             :weather_interval_ms,
             :drand_enabled,
             :bluesky_enabled,
             :ripe_enabled,
             :ripe_collectors,
             :solana_enabled
           ]}

  @boolean_settings [
    enabled: "WORLDLOOM_FEEDS_ENABLED",
    drand_enabled: "WORLDLOOM_DRAND_ENABLED",
    bluesky_enabled: "WORLDLOOM_BLUESKY_ENABLED",
    ripe_enabled: "WORLDLOOM_RIPE_ENABLED",
    solana_enabled: "WORLDLOOM_SOLANA_ENABLED"
  ]
  @settings [
    :enabled,
    :wikimedia_url,
    :usgs_url,
    :open_meteo_url,
    :earthquake_interval_ms,
    :weather_interval_ms,
    :drand_enabled,
    :drand_relays,
    :bluesky_enabled,
    :bluesky_url,
    :ripe_enabled,
    :ripe_url,
    :ripe_collectors,
    :solana_enabled,
    :solana_url
  ]
  @enforce_keys @settings
  defstruct @enforce_keys

  @type environment :: :dev | :test | :prod
  @type t :: %__MODULE__{
          enabled: boolean(),
          wikimedia_url: String.t(),
          usgs_url: String.t(),
          open_meteo_url: String.t(),
          earthquake_interval_ms: pos_integer(),
          weather_interval_ms: pos_integer(),
          drand_enabled: boolean(),
          drand_relays: [String.t()],
          bluesky_enabled: boolean(),
          bluesky_url: String.t(),
          ripe_enabled: boolean(),
          ripe_url: String.t(),
          ripe_collectors: [String.t()],
          solana_enabled: boolean(),
          solana_url: String.t() | nil
        }

  @spec from_keyword!(keyword() | t(), environment()) :: t()
  def from_keyword!(%__MODULE__{} = settings, environment) do
    settings
    |> Map.from_struct()
    |> Map.to_list()
    |> from_keyword!(environment)
  end

  def from_keyword!(settings, environment)
      when is_list(settings) and environment in [:dev, :test, :prod] do
    validate_keyword!(settings)

    configured =
      settings
      |> Map.new()
      |> parse_booleans!()
      |> parse_collections!()
      |> validate_intervals!()
      |> validate_endpoints!(environment)
      |> validate_drand_origins!()
      |> apply_global_switch()
      |> validate_source_requirements!()

    struct!(__MODULE__, configured)
  end

  def from_keyword!(_settings, environment) when environment not in [:dev, :test, :prod] do
    raise ArgumentError, "signal configuration environment must be dev, test, or prod"
  end

  def from_keyword!(_settings, _environment) do
    raise ArgumentError, "signal configuration must be a keyword list"
  end

  defp validate_keyword!(settings) do
    unless Keyword.keyword?(settings) do
      raise ArgumentError, "signal configuration must be a keyword list"
    end

    known_keys = MapSet.new(@settings)
    provided_keys = MapSet.new(Keyword.keys(settings))

    unknown_keys =
      settings
      |> Keyword.keys()
      |> Enum.reject(&MapSet.member?(known_keys, &1))
      |> Enum.uniq()
      |> Enum.sort()

    if unknown_keys != [] do
      raise ArgumentError, "signal configuration has unknown keys: #{inspect(unknown_keys)}"
    end

    missing_keys =
      known_keys
      |> MapSet.difference(provided_keys)
      |> MapSet.to_list()
      |> Enum.sort()

    if missing_keys != [] do
      raise ArgumentError, "signal configuration has missing keys: #{inspect(missing_keys)}"
    end

    duplicate_keys =
      settings
      |> Keyword.keys()
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicate_keys != [] do
      raise ArgumentError, "signal configuration has duplicate keys: #{inspect(duplicate_keys)}"
    end
  end

  defp parse_booleans!(configured) do
    Enum.reduce(@boolean_settings, configured, fn {setting, environment_key}, parsed ->
      Map.update!(parsed, setting, &parse_boolean!(&1, environment_key))
    end)
  end

  defp parse_boolean!(enabled, _environment_key) when is_boolean(enabled), do: enabled
  defp parse_boolean!("true", _environment_key), do: true
  defp parse_boolean!("false", _environment_key), do: false

  defp parse_boolean!(_invalid, environment_key) do
    raise ArgumentError, "environment variable #{environment_key} must be true or false"
  end

  defp parse_collections!(configured) do
    configured
    |> Map.update!(:drand_relays, &parse_relay_list!/1)
    |> Map.update!(:ripe_collectors, &parse_collector_list!/1)
  end

  defp parse_relay_list!(relays) do
    relays = parse_csv_or_list(relays)

    if length(relays) in 1..3 and Enum.uniq(relays) == relays do
      relays
    else
      raise ArgumentError,
            "environment variable WORLDLOOM_DRAND_RELAYS must contain one to three unique URLs"
    end
  end

  defp parse_collector_list!(collectors) do
    collectors = parse_csv_or_list(collectors)

    if length(collectors) in 1..4 and Enum.uniq(collectors) == collectors and
         Enum.all?(collectors, &Regex.match?(~r/^rrc\d{2}$/, &1)) do
      collectors
    else
      raise ArgumentError,
            "environment variable WORLDLOOM_RIPE_COLLECTORS must contain one to four unique rrcNN collectors"
    end
  end

  defp parse_csv_or_list(entries) when is_binary(entries) do
    entries
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_csv_or_list(entries) when is_list(entries) do
    if Enum.all?(entries, &is_binary/1), do: entries, else: []
  end

  defp parse_csv_or_list(_invalid), do: []

  defp validate_intervals!(configured) do
    for {setting, environment_key} <- [
          earthquake_interval_ms: "WORLDLOOM_EARTHQUAKE_INTERVAL_MS",
          weather_interval_ms: "WORLDLOOM_WEATHER_INTERVAL_MS"
        ] do
      interval = Map.fetch!(configured, setting)

      unless is_integer(interval) and interval > 0 do
        raise ArgumentError, "configuration #{environment_key} must be a positive integer"
      end
    end

    configured
  end

  defp validate_endpoints!(configured, environment) do
    configured
    |> validate_url!(:wikimedia_url, "WORLDLOOM_WIKIMEDIA_URL", :http, environment)
    |> validate_url!(:usgs_url, "WORLDLOOM_USGS_URL", :http, environment)
    |> validate_url!(:open_meteo_url, "WORLDLOOM_OPEN_METEO_URL", :http, environment)
    |> validate_urls!(:drand_relays, "WORLDLOOM_DRAND_RELAYS", :http, environment)
    |> validate_url!(:bluesky_url, "WORLDLOOM_BLUESKY_URL", :websocket, environment)
    |> validate_url!(:ripe_url, "WORLDLOOM_RIPE_URL", :websocket, environment)
    |> validate_optional_url!(:solana_url, "WORLDLOOM_SOLANA_URL", :websocket, environment)
  end

  defp validate_urls!(configured, setting, environment_key, kind, environment) do
    Enum.each(
      configured[setting],
      &validate_absolute_url!(&1, environment_key, kind, environment)
    )

    configured
  end

  defp validate_url!(configured, setting, environment_key, kind, environment) do
    validate_absolute_url!(configured[setting], environment_key, kind, environment)
    configured
  end

  defp validate_optional_url!(configured, setting, environment_key, kind, environment) do
    case configured[setting] do
      nil -> configured
      _url -> validate_url!(configured, setting, environment_key, kind, environment)
    end
  end

  defp validate_drand_origins!(configured) do
    if Enum.all?(configured.drand_relays, &(&1 in DrandClient.allowed_origins())) do
      configured
    else
      raise ArgumentError,
            "environment variable WORLDLOOM_DRAND_RELAYS must select official drand HTTPS origins"
    end
  end

  defp validate_absolute_url!(url, environment_key, kind, environment) do
    allowed_schemes = allowed_schemes(kind, environment)

    valid? =
      with true <- is_binary(url) and url != "",
           {:ok, uri} <- URI.new(url),
           true <- uri.scheme in allowed_schemes,
           true <- is_binary(uri.host) and uri.host != "",
           true <- is_nil(uri.userinfo),
           true <- is_nil(uri.port) or uri.port in 1..65_535 do
        true
      else
        _invalid -> false
      end

    unless valid? do
      protocol =
        if environment == :prod or kind == :websocket,
          do: secure_protocol(kind),
          else: protocol(kind)

      raise ArgumentError,
            "environment variable #{environment_key} must be an absolute #{protocol} URL without credentials"
    end
  end

  defp allowed_schemes(:http, :prod), do: ["https"]
  defp allowed_schemes(:http, _environment), do: ["http", "https"]
  defp allowed_schemes(:websocket, _environment), do: ["wss"]

  defp secure_protocol(:http), do: "HTTPS"
  defp secure_protocol(:websocket), do: "WSS"
  defp protocol(:http), do: "HTTP(S)"

  defp apply_global_switch(%{enabled: true} = configured), do: configured

  defp apply_global_switch(%{enabled: false} = configured) do
    Map.merge(configured, %{
      drand_enabled: false,
      bluesky_enabled: false,
      ripe_enabled: false,
      solana_enabled: false
    })
  end

  defp validate_source_requirements!(%{solana_enabled: true, solana_url: nil}) do
    raise ArgumentError,
          "environment variable WORLDLOOM_SOLANA_URL is required when WORLDLOOM_SOLANA_ENABLED is true"
  end

  defp validate_source_requirements!(configured), do: configured
end
