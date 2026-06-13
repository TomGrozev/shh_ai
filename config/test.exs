import Config

# The proxy is stateless - no database required for testing
# We use ETS for session storage

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :shh_ai, ShhAiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vND++Pn9Y0d4ugwEXidlkcbO8UuA4gS9V6IfcphofgvVJOMJ3Vw2lm50D+Ma1Wk8",
  server: false

# In test we don't send emails
config :shh_ai, ShhAi.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true


# Fixed namespace UUID for tests - allows deterministic conversation IDs.
config :shh_ai, ShhAi.ConversationFingerprinter,
  namespace_uuid: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
