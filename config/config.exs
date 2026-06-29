# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :shh_ai,
  generators: [timestamp_type: :utc_datetime]

config :shh_ai, ecto_repos: [ShhAi.Repo]

# Configure the endpoint
config :shh_ai, ShhAiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ShhAiWeb.ErrorHTML, json: ShhAiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ShhAi.PubSub,
  live_view: [signing_salt: "aehM3xXm"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :shh_ai, ShhAi.Mailer, adapter: Swoosh.Adapters.Local

# Audit Mode Ecto Repo (SQLite, write-only)
config :shh_ai, ShhAi.Repo,
  database: "priv/audit/audit.db",
  pool_size: 5,
  journal_mode: :wal

# Audit Mode Cloak Vault (AES-256-GCM). The key is loaded from
# AUDIT_ENCRYPTION_KEY in ShhAi.Audit.Vault.init/1.
config :shh_ai, ShhAi.Audit.Vault,
  ciphers: [
    default: {Cloak.Ciphers.AES.GCM, tag: "v1", key: nil}
  ]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  shh_ai: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  shh_ai: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
