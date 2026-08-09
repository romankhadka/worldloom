# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :worldloom,
  ecto_repos: [Worldloom.Repo],
  generators: [timestamp_type: :utc_datetime],
  secure_cookies: false,
  rate_limit_salt: "worldloom-development-only-rate-limit-salt"

config :worldloom, Worldloom.Signals,
  enabled: true,
  wikimedia_url: "https://stream.wikimedia.org/v2/stream/recentchange",
  usgs_url: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson",
  open_meteo_url: "https://api.open-meteo.com/v1/forecast",
  earthquake_interval_ms: 60_000,
  weather_interval_ms: 600_000,
  drand_enabled: false,
  drand_relays: [
    "https://api.drand.sh",
    "https://api2.drand.sh",
    "https://api3.drand.sh"
  ],
  bluesky_enabled: false,
  bluesky_url: "wss://jetstream2.us-west.bsky.network/subscribe",
  ripe_enabled: false,
  ripe_url: "wss://ris-live.ripe.net/v1/ws/",
  ripe_collectors: ["rrc00", "rrc01", "rrc03", "rrc10"],
  solana_enabled: false,
  solana_url: nil

# Configures the endpoint
config :worldloom, WorldloomWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WorldloomWeb.ErrorHTML, json: WorldloomWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Worldloom.PubSub,
  live_view: [signing_salt: "0ughJWQ/"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :worldloom, Worldloom.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  worldloom: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  worldloom: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
