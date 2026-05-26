# No database

This application operates as a stateless proxy with no persistent write model. There is no Ecto, no Postgres, and no need for `mix ecto.setup`. All configuration is environment-driven, sessions are ephemeral (stored in ETS or Redis), and the only durable state lives in the external AI providers themselves. This keeps the deployment footprint small, removes a whole class of operational concerns, and aligns with the project's goal of being a lightweight PII-sanitizing gateway rather than a data-collecting platform.
