defmodule HelloLive.Repo do
  use Ecto.Repo,
    otp_app: :hello_live,
    adapter: Ecto.Adapters.Postgres
end
