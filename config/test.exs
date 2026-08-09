import Config

config :worldloom, Worldloom.Signals,
  enabled: false,
  drand_enabled: false,
  bluesky_enabled: false,
  ripe_enabled: false,
  solana_enabled: false

e2e? = System.get_env("WORLDLOOM_E2E") == "true"
config :worldloom, :acceptance_scene_diagnostics, e2e?
config :worldloom, :e2e_routes, e2e?
config :worldloom, Worldloom.Loom.Coordinator, bootstrap: if(e2e?, do: :store, else: :empty)
config :worldloom, WorldloomWeb.Telemetry, periodic_measurements: e2e?

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :worldloom, Worldloom.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database:
    if(e2e?, do: "worldloom_e2e", else: "worldloom_test#{System.get_env("MIX_TEST_PARTITION")}"),
  pool: if(e2e?, do: DBConnection.ConnectionPool, else: Ecto.Adapters.SQL.Sandbox),
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :worldloom, WorldloomWeb.Endpoint,
  url: [host: "localhost", port: 4002],
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CvUZrdJ8hBxL2+rKbevnebnowgVi6IMZO4mEPODfyexphR4GAAnaQcmMqMyN9SoY"

# In test we don't send emails
config :worldloom, Worldloom.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
