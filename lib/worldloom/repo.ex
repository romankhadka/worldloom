defmodule Worldloom.Repo do
  use Ecto.Repo,
    otp_app: :worldloom,
    adapter: Ecto.Adapters.Postgres
end
