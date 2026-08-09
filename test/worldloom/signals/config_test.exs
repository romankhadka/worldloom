defmodule Worldloom.Signals.ConfigTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.Config
  alias Worldloom.Signals.DrandClient
  alias Worldloom.Signals.SafeEndpoint

  @boolean_settings [
    enabled: "WORLDLOOM_FEEDS_ENABLED",
    drand_enabled: "WORLDLOOM_DRAND_ENABLED",
    bluesky_enabled: "WORLDLOOM_BLUESKY_ENABLED",
    ripe_enabled: "WORLDLOOM_RIPE_ENABLED",
    solana_enabled: "WORLDLOOM_SOLANA_ENABLED"
  ]

  test "loads secure defaults with every qualified source enabled" do
    config = Config.from_keyword!(default_config(), :dev)

    assert config.enabled
    assert config.drand_enabled
    assert config.bluesky_enabled
    assert config.ripe_enabled
    assert config.solana_enabled

    assert config.drand_relays == [
             "https://api.drand.sh",
             "https://api2.drand.sh",
             "https://api3.drand.sh"
           ]

    assert config.bluesky_url == "wss://jetstream2.us-west.bsky.network/subscribe"
    assert config.ripe_url == "wss://ris-live.ripe.net/v1/ws/"
    assert config.ripe_collectors == ["rrc00", "rrc01", "rrc03", "rrc10"]
    assert config.solana_url == "wss://api.mainnet-beta.solana.com/"
    assert Config.from_keyword!(config, :prod) == config
  end

  test "accepts native booleans and only literal lowercase boolean strings" do
    for {setting, _environment_key} <- @boolean_settings,
        accepted <- [true, false, "true", "false"] do
      settings = Keyword.put(default_config(), setting, accepted)

      settings =
        if setting == :solana_enabled and accepted in [true, "true"] do
          Keyword.put(settings, :solana_url, "wss://localhost:9443")
        else
          settings
        end

      config = Config.from_keyword!(settings, :dev)
      assert Map.fetch!(config, setting) == accepted in [true, "true"]
    end
  end

  test "names the environment key when a boolean is invalid" do
    for {setting, environment_key} <- @boolean_settings,
        invalid <- ["TRUE", "False", "1", "yes", "", nil, 1] do
      assert_raise ArgumentError, ~r/#{environment_key}.*true or false/, fn ->
        default_config()
        |> Keyword.put(setting, invalid)
        |> Config.from_keyword!(:dev)
      end
    end
  end

  test "a global disable overrides every source flag in every environment" do
    for environment <- [:dev, :test, :prod] do
      config =
        default_config()
        |> Keyword.merge(
          enabled: "false",
          drand_enabled: "true",
          bluesky_enabled: "true",
          ripe_enabled: "true",
          solana_enabled: "true"
        )
        |> Config.from_keyword!(environment)

      refute config.enabled
      refute config.drand_enabled
      refute config.bluesky_enabled
      refute config.ripe_enabled
      refute config.solana_enabled
    end
  end

  test "production requires HTTPS for every HTTP source" do
    for setting <- [:wikimedia_url, :usgs_url, :open_meteo_url] do
      environment_key = environment_key(setting)

      assert_raise ArgumentError, ~r/#{environment_key}.*HTTPS URL/, fn ->
        default_config()
        |> Keyword.put(setting, "http://provider.example.test/feed")
        |> Config.from_keyword!(:prod)
      end
    end

    assert_raise ArgumentError, ~r/WORLDLOOM_DRAND_RELAYS.*HTTPS URL/, fn ->
      default_config()
      |> Keyword.put(:drand_relays, ["https://api.drand.sh", "http://relay.example.test"])
      |> Config.from_keyword!(:prod)
    end
  end

  test "every environment requires WSS for configured WebSocket sources" do
    for {setting, environment_key} <- [
          bluesky_url: "WORLDLOOM_BLUESKY_URL",
          ripe_url: "WORLDLOOM_RIPE_URL",
          solana_url: "WORLDLOOM_SOLANA_URL"
        ],
        environment <- [:dev, :test, :prod] do
      assert_raise ArgumentError, ~r/#{environment_key}.*WSS URL/, fn ->
        default_config()
        |> Keyword.put(setting, "ws://provider.example.test/feed")
        |> Config.from_keyword!(environment)
      end
    end
  end

  test "development permits local HTTP while retaining secure WebSockets" do
    config =
      default_config()
      |> Keyword.merge(
        wikimedia_url: "http://localhost:4100/wikimedia",
        bluesky_url: "wss://localhost:4103/bluesky",
        ripe_url: "wss://localhost:4104/ripe"
      )
      |> Config.from_keyword!(:dev)

    assert config.wikimedia_url == "http://localhost:4100/wikimedia"
    assert config.drand_relays == DrandClient.allowed_origins()
    assert config.bluesky_url == "wss://localhost:4103/bluesky"
    assert config.ripe_url == "wss://localhost:4104/ripe"
  end

  test "parses bounded RIPE collector strings" do
    config =
      default_config()
      |> Keyword.put(:ripe_collectors, " rrc00,rrc03, rrc10 ")
      |> Config.from_keyword!(:prod)

    assert config.ripe_collectors == ["rrc00", "rrc03", "rrc10"]

    for invalid <- [
          "",
          "rrc00,rrc01,rrc03,rrc10,rrc11",
          "rrc0",
          "rrc000",
          "rrcAA",
          "rrc00,rrc00",
          []
        ] do
      assert_raise ArgumentError, ~r/WORLDLOOM_RIPE_COLLECTORS.*one to four/, fn ->
        default_config()
        |> Keyword.put(:ripe_collectors, invalid)
        |> Config.from_keyword!(:prod)
      end
    end
  end

  test "parses relay strings and rejects empty or over-wide relay sets" do
    config =
      default_config()
      |> Keyword.put(:drand_relays, " https://api.drand.sh,https://api2.drand.sh ")
      |> Config.from_keyword!(:prod)

    assert config.drand_relays == ["https://api.drand.sh", "https://api2.drand.sh"]

    for invalid <- ["", [], ["https://api.drand.sh", "https://api.drand.sh"]] do
      assert_raise ArgumentError, ~r/WORLDLOOM_DRAND_RELAYS.*one to three/, fn ->
        default_config()
        |> Keyword.put(:drand_relays, invalid)
        |> Config.from_keyword!(:prod)
      end
    end
  end

  test "accepts only relay origins the drand client can start" do
    for {environment, origin} <- [
          {:dev, "http://localhost:4101"},
          {:prod, "https://relay.example.test"},
          {:prod, "https://api.drand.sh?token=private"}
        ] do
      assert_raise ArgumentError, ~r/WORLDLOOM_DRAND_RELAYS.*official drand HTTPS origins/, fn ->
        default_config()
        |> Keyword.put(:drand_relays, [origin])
        |> Config.from_keyword!(environment)
      end
    end
  end

  test "configured endpoint labels cannot expose query parameters" do
    config =
      default_config()
      |> Keyword.merge(
        wikimedia_url: "https://provider.example.test/wiki?token=wiki-secret",
        usgs_url: "https://provider.example.test/usgs?token=usgs-secret",
        open_meteo_url: "https://provider.example.test/weather?token=weather-secret",
        bluesky_url: "wss://provider.example.test/bluesky?cursor=bluesky-secret",
        ripe_url: "wss://provider.example.test/ripe?token=ripe-secret",
        solana_url: "wss://provider.example.test/solana?token=solana-secret"
      )
      |> Config.from_keyword!(:prod)

    configured_urls =
      [
        config.wikimedia_url,
        config.usgs_url,
        config.open_meteo_url,
        config.bluesky_url,
        config.ripe_url,
        config.solana_url
      ] ++ config.drand_relays

    for url <- configured_urls do
      label = SafeEndpoint.label(url)

      refute label =~ "?"
      refute label =~ "secret"
    end

    refute inspect(config) =~ "?"
    refute inspect(config) =~ "secret"
  end

  test "URL validation errors never echo a configured query" do
    invalid_config =
      Keyword.put(
        default_config(),
        :bluesky_url,
        "ws://provider.example.test/bluesky?token=private-error-marker"
      )

    error =
      assert_raise ArgumentError, ~r/WORLDLOOM_BLUESKY_URL.*WSS URL/, fn ->
        Config.from_keyword!(invalid_config, :prod)
      end

    refute Exception.message(error) =~ "private-error-marker"
    refute Exception.message(error) =~ "?"
  end

  test "every environment requires an endpoint when Solana is enabled" do
    for environment <- [:dev, :test, :prod] do
      assert_raise ArgumentError,
                   ~r/WORLDLOOM_SOLANA_URL.*required.*WORLDLOOM_SOLANA_ENABLED.*true/,
                   fn ->
                     default_config()
                     |> Keyword.merge(solana_enabled: "true", solana_url: nil)
                     |> Config.from_keyword!(environment)
                   end
    end
  end

  test "rejects unknown settings instead of silently ignoring misspellings" do
    assert_raise ArgumentError, ~r/unknown keys.*drnad_enabled/, fn ->
      Config.from_keyword!([{:drnad_enabled, true} | default_config()], :dev)
    end
  end

  test "rejects missing settings instead of carrying a second defaults source" do
    assert_raise ArgumentError, ~r/missing keys.*enabled.*wikimedia_url/, fn ->
      Config.from_keyword!([], :dev)
    end
  end

  defp default_config do
    "config/config.exs"
    |> Elixir.Config.Reader.read!(env: :dev)
    |> get_in([:worldloom, Worldloom.Signals])
  end

  defp environment_key(:wikimedia_url), do: "WORLDLOOM_WIKIMEDIA_URL"
  defp environment_key(:usgs_url), do: "WORLDLOOM_USGS_URL"
  defp environment_key(:open_meteo_url), do: "WORLDLOOM_OPEN_METEO_URL"
end
