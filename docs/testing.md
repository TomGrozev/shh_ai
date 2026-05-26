# Testing

## PII Detection Test Setup

Tests involving PII detection need to load patterns into `:persistent_term`:

```elixir
setup do
  ShhAi.Config.load()           # Loads all config including providers
  ShhAi.PII.Patterns.load_into_persistent_term()  # Loads regex patterns
  :ok
end
```

For tests that only need patterns (no config):

```elixir
setup do
  ShhAi.PII.Patterns.load_into_persistent_term()
  :ok
end
```
