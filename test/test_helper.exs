ExUnit.start()

unless Application.get_env(:worldloom, :e2e_routes, false) do
  Ecto.Adapters.SQL.Sandbox.mode(Worldloom.Repo, :manual)
end
