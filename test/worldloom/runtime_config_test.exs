defmodule Worldloom.RuntimeConfigTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @production_environment %{
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/worldloom_runtime_config_test",
    "PHX_HOST" => "worldloom.test",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "WORLDLOOM_RATE_LIMIT_SALT" => "runtime-config-test-salt",
    "WORLDLOOM_FEEDS_ENABLED" => "false"
  }
  @signal_environment_keys ~w(
    WORLDLOOM_FEEDS_ENABLED
    WORLDLOOM_WIKIMEDIA_URL
    WORLDLOOM_USGS_URL
    WORLDLOOM_OPEN_METEO_URL
    WORLDLOOM_DRAND_ENABLED
    WORLDLOOM_DRAND_RELAYS
    WORLDLOOM_BLUESKY_ENABLED
    WORLDLOOM_BLUESKY_URL
    WORLDLOOM_RIPE_ENABLED
    WORLDLOOM_RIPE_URL
    WORLDLOOM_RIPE_COLLECTORS
    WORLDLOOM_SOLANA_ENABLED
  )

  setup do
    managed_environment_keys =
      Enum.uniq(Map.keys(@production_environment) ++ @signal_environment_keys)

    original_environment = Map.new(managed_environment_keys, &{&1, System.get_env(&1)})
    original_signal_config = Application.fetch_env!(:worldloom, Worldloom.Signals)

    on_exit(fn ->
      restore_environment(original_environment)
      Application.put_env(:worldloom, Worldloom.Signals, original_signal_config)
    end)

    Enum.each(managed_environment_keys, &System.delete_env/1)
    Enum.each(@production_environment, fn {key, setting} -> System.put_env(key, setting) end)

    enabled_signal_config =
      case original_signal_config do
        %Worldloom.Signals.Config{} = config -> %{config | enabled: true}
        config when is_list(config) -> Keyword.put(config, :enabled, true)
      end

    Application.put_env(:worldloom, Worldloom.Signals, enabled_signal_config)

    :ok
  end

  test "production requires an explicit public host" do
    System.delete_env("PHX_HOST")

    assert_raise RuntimeError, ~r/PHX_HOST.*missing/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "production preserves the explicit feed-disable override" do
    System.put_env("WORLDLOOM_DRAND_ENABLED", "true")
    System.put_env("WORLDLOOM_BLUESKY_ENABLED", "true")
    System.put_env("WORLDLOOM_RIPE_ENABLED", "true")
    System.put_env("WORLDLOOM_SOLANA_ENABLED", "true")

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    signal_config = runtime_config[:worldloom][Worldloom.Signals]

    assert %Worldloom.Signals.Config{} = signal_config
    refute signal_config.enabled
    refute signal_config.drand_enabled
    refute signal_config.bluesky_enabled
    refute signal_config.ripe_enabled
    refute signal_config.solana_enabled
  end

  test "production parses independent source settings into native values" do
    System.put_env("WORLDLOOM_FEEDS_ENABLED", "true")
    System.put_env("WORLDLOOM_DRAND_ENABLED", "true")
    System.put_env("WORLDLOOM_DRAND_RELAYS", "https://api.drand.sh,https://api2.drand.sh")
    System.put_env("WORLDLOOM_BLUESKY_ENABLED", "true")
    System.put_env("WORLDLOOM_BLUESKY_URL", "wss://bluesky.example.test/subscribe?token=private")
    System.put_env("WORLDLOOM_RIPE_ENABLED", "true")
    System.put_env("WORLDLOOM_RIPE_URL", "wss://ripe.example.test/ws?token=private")
    System.put_env("WORLDLOOM_RIPE_COLLECTORS", "rrc00,rrc03")

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    signal_config = runtime_config[:worldloom][Worldloom.Signals]

    assert %Worldloom.Signals.Config{} = signal_config
    assert signal_config.enabled
    assert signal_config.drand_enabled
    assert signal_config.drand_relays == ["https://api.drand.sh", "https://api2.drand.sh"]
    assert signal_config.bluesky_enabled
    assert signal_config.bluesky_url == "wss://bluesky.example.test/subscribe?token=private"
    assert signal_config.ripe_enabled
    assert signal_config.ripe_url == "wss://ripe.example.test/ws?token=private"
    assert signal_config.ripe_collectors == ["rrc00", "rrc03"]
    refute signal_config.solana_enabled
    refute inspect(signal_config) =~ "private"
    refute inspect(signal_config) =~ "?"
  end

  test "production rejects invalid source booleans with the environment key" do
    System.put_env("WORLDLOOM_DRAND_ENABLED", "1")

    assert_raise ArgumentError, ~r/WORLDLOOM_DRAND_ENABLED.*true or false/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "production endpoint failures do not expose URL queries" do
    System.put_env("WORLDLOOM_FEEDS_ENABLED", "true")

    System.put_env(
      "WORLDLOOM_BLUESKY_URL",
      "ws://bluesky.example.test/subscribe?token=private-runtime-marker"
    )

    error =
      assert_raise ArgumentError, ~r/WORLDLOOM_BLUESKY_URL.*WSS URL/, fn ->
        Config.Reader.read!("config/runtime.exs", env: :prod)
      end

    refute Exception.message(error) =~ "private-runtime-marker"
    refute Exception.message(error) =~ "?"
  end

  test "production keeps Solana disabled until its endpoint decision is approved" do
    System.put_env("WORLDLOOM_FEEDS_ENABLED", "true")
    System.put_env("WORLDLOOM_SOLANA_ENABLED", "true")

    assert_raise ArgumentError, ~r/WORLDLOOM_SOLANA_ENABLED.*production endpoint decision/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "production redirects direct HTTP while accepting Fly-forwarded HTTPS health checks" do
    production_config = Config.Reader.read!("config/prod.exs", env: :prod)
    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)
    endpoint_config = production_config[:worldloom][WorldloomWeb.Endpoint]
    runtime_endpoint_config = runtime_config[:worldloom][WorldloomWeb.Endpoint]

    assert endpoint_config[:force_ssl] == [hsts: true, rewrite_on: [:x_forwarded_proto]]
    assert runtime_endpoint_config[:check_origin] == ["https://worldloom.test"]

    ssl_options = Plug.SSL.init(endpoint_config[:force_ssl])

    redirected_conn =
      :get
      |> conn("http://worldloom.test/")
      |> Plug.SSL.call(ssl_options)

    assert redirected_conn.halted
    assert redirected_conn.status == 301
    assert get_resp_header(redirected_conn, "location") == ["https://worldloom.test/"]

    forwarded_health_conn =
      :get
      |> conn("http://worldloom.test/healthz")
      |> put_req_header("x-forwarded-proto", "https")
      |> Plug.SSL.call(ssl_options)

    refute forwarded_health_conn.halted
    assert forwarded_health_conn.scheme == :https
    assert get_resp_header(forwarded_health_conn, "strict-transport-security") != []
  end

  defp restore_environment(environment) do
    Enum.each(environment, fn
      {key, nil} -> System.delete_env(key)
      {key, setting} -> System.put_env(key, setting)
    end)
  end
end
