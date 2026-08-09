defmodule WorldloomWeb.HealthControllerTest do
  use WorldloomWeb.ConnCase, async: false

  alias Worldloom.Signals.BalanceMonitor

  defmodule AvailableRepo do
    def query("SELECT 1", [], options) do
      if Keyword.get(options, :timeout) == 1_000 do
        {:ok, %{rows: [[1]]}}
      else
        {:error, :missing_timeout}
      end
    end
  end

  defmodule UnavailableRepo do
    def query("SELECT 1", [], _options), do: {:error, :database_unavailable}
  end

  setup do
    original_configuration =
      Application.get_env(:worldloom, WorldloomWeb.HealthController, [])

    on_exit(fn ->
      Application.put_env(
        :worldloom,
        WorldloomWeb.HealthController,
        original_configuration
      )
    end)

    :ok
  end

  test "returns only the public healthy response when Repo and Coordinator are available", %{
    conn: conn
  } do
    Application.put_env(:worldloom, WorldloomWeb.HealthController,
      repo: AvailableRepo,
      coordinator: Worldloom.Loom.Coordinator
    )

    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 200) == %{"status" => "ok"}
    assert conn.resp_body == ~s({"status":"ok"})
    refute conn.resp_body =~ "wikimedia"
    refute conn.resp_body =~ "checkpoint"
  end

  test "returns only unavailable when the database check fails", %{conn: conn} do
    Application.put_env(:worldloom, WorldloomWeb.HealthController,
      repo: UnavailableRepo,
      coordinator: Worldloom.Loom.Coordinator
    )

    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 503) == %{"status" => "unavailable"}
    assert conn.resp_body == ~s({"status":"unavailable"})
    refute conn.resp_body =~ "database_unavailable"
  end

  test "returns only unavailable when the Coordinator is absent", %{conn: conn} do
    Application.put_env(:worldloom, WorldloomWeb.HealthController,
      repo: AvailableRepo,
      coordinator: :worldloom_missing_coordinator
    )

    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 503) == %{"status" => "unavailable"}
    assert conn.resp_body == ~s({"status":"unavailable"})
    refute conn.resp_body =~ "worldloom_missing_coordinator"
  end

  test "remains healthy while the balance monitor is intentionally absent", %{conn: conn} do
    Application.put_env(:worldloom, WorldloomWeb.HealthController,
      repo: AvailableRepo,
      coordinator: Worldloom.Loom.Coordinator
    )

    assert is_pid(Process.whereis(BalanceMonitor))
    :ok = Supervisor.terminate_child(Worldloom.Supervisor, BalanceMonitor)

    on_exit(fn ->
      if is_nil(Process.whereis(BalanceMonitor)) do
        {:ok, _monitor} = Supervisor.restart_child(Worldloom.Supervisor, BalanceMonitor)
      end
    end)

    assert is_nil(Process.whereis(BalanceMonitor))

    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 200) == %{"status" => "ok"}
    assert conn.resp_body == ~s({"status":"ok"})

    {:ok, restarted_monitor} = Supervisor.restart_child(Worldloom.Supervisor, BalanceMonitor)
    assert is_pid(restarted_monitor)
  end
end
