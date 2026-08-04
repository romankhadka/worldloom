defmodule Worldloom.ReleaseTest do
  use Worldloom.DataCase, async: false

  alias Worldloom.Release
  alias Worldloom.Repo

  test "migrates every configured repository and leaves it available" do
    assert :ok = Release.migrate()
    assert {:ok, _query} = Repo.query("SELECT 1")
  end

  test "production container starts the Phoenix endpoint by default" do
    dockerfile = File.read!("Dockerfile")

    assert dockerfile =~ ~s(ENV PHX_SERVER="true")
  end
end
