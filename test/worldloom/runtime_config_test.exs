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

  setup do
    original_environment = Map.new(Map.keys(@production_environment), &{&1, System.get_env(&1)})
    original_signal_config = Application.fetch_env!(:worldloom, Worldloom.Signals)

    on_exit(fn ->
      restore_environment(original_environment)
      Application.put_env(:worldloom, Worldloom.Signals, original_signal_config)
    end)

    Enum.each(@production_environment, fn {key, setting} -> System.put_env(key, setting) end)

    Application.put_env(
      :worldloom,
      Worldloom.Signals,
      Keyword.put(original_signal_config, :enabled, true)
    )

    :ok
  end

  test "production requires an explicit public host" do
    System.delete_env("PHX_HOST")

    assert_raise RuntimeError, ~r/PHX_HOST.*missing/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "production preserves the explicit feed-disable override" do
    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)

    assert runtime_config[:worldloom][Worldloom.Signals][:enabled] == false
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
