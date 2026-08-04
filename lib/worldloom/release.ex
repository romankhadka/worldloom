defmodule Worldloom.Release do
  @moduledoc """
  Runtime entry points used by an assembled Worldloom release.
  """

  @app :worldloom

  @spec migrate() :: :ok
  def migrate do
    load_application()

    Enum.each(repositories(), fn repo ->
      {:ok, _migrations, _started_apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end)

    :ok
  end

  defp load_application do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end

  defp repositories, do: Application.fetch_env!(@app, :ecto_repos)
end
