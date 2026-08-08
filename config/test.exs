import Config

# Disable NER model loading in the test environment.
# The NER BERT-small model (~110MB) loads during Application.start/2 via
# Config.load() -> load_pii_config() when PII_NER_ENABLED is true (its default).
# Once loaded, every ShhAi.PII.Detector.detect/2 call pays ~1-4s of BERT inference,
# making the otherwise-fast regex detector tests take 100s instead of 10s.
# NER-dependent tests live in test/shh_ai/pii/ner_test.exs (@moduletag :ner, excluded
# by default) and explicitly call NER.init/0 in their setup, so they are unaffected.
System.put_env("PII_NER_ENABLED", "false")

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
config :shh_ai, ShhAi.Conversation.Fingerprinter,
  namespace_uuid: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

# Default the audit DB to a per-process tmp path so the application
# supervisor boots ShhAi.Repo against a writable file. Individual
# tests override this and restart the Repo for isolation.
config :shh_ai, audit_db_path: Path.join(System.tmp_dir!(), "shh_ai_test_repo.db")
