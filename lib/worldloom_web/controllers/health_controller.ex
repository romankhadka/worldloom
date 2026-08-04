defmodule WorldloomWeb.HealthController do
  use WorldloomWeb, :controller

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Repo

  @database_timeout 1_000

  def index(conn, _params) do
    if available?() do
      json(conn, %{status: "ok"})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "unavailable"})
    end
  end

  defp available? do
    configuration =
      Application.get_env(
        :worldloom,
        __MODULE__,
        repo: Repo,
        coordinator: Coordinator
      )

    repo_available?(Keyword.fetch!(configuration, :repo)) and
      coordinator_available?(Keyword.fetch!(configuration, :coordinator))
  end

  defp repo_available?(repo) do
    match?({:ok, _query_result}, repo.query("SELECT 1", [], timeout: @database_timeout))
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  defp coordinator_available?(coordinator) when is_atom(coordinator) do
    coordinator |> Process.whereis() |> is_pid()
  end

  defp coordinator_available?(coordinator) when is_pid(coordinator),
    do: Process.alive?(coordinator)

  defp coordinator_available?(_coordinator), do: false
end
