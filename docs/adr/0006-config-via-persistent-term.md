# Config is stored in `:persistent_term` at boot

All application configuration is loaded once at startup by `ShhAi.Config.load()` and stored in `:persistent_term`. Reads are therefore zero-cost BEAM lookups rather than repeated file or environment variable access. Configuration is immutable at runtime; any change requires a restart. This is appropriate because provider credentials and feature flags change rarely, and the performance gain on every request justifies the static-lifetime constraint.
