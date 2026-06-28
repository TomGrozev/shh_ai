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

## Integration Tests

Integration tests exercise the full Phoenix request stack end-to-end against real LLM provider backends (OpenAI, Anthropic, Ollama). They live in `test/integration/`, are tagged `:integration` and `:"integration_<provider>"`, and are **excluded from the default `mix test` run** — they must be opted into explicitly.

### Running

```
mix test.integration
```

or equivalently:

```
mix test --only integration
```

To run only one provider (e.g. only OpenAI):

```
    mix test --only integration_openai
```

### What the tests cover

* `openai_integration_test.exs` — `POST /v1/chat/completions` (non-streaming + streaming), `POST /v1/embeddings`, `GET /v1/models`, `POST /v1/completions` (legacy), and a PII roundtrip test that proves the proxy sanitizes a fresh email address before forwarding (the original email never appears in the LLM's response).
* `anthropic_integration_test.exs` — `POST /v1/messages` (non-streaming + streaming), and a PII roundtrip test.
* `ollama_integration_test.exs` — `GET /api/tags`, `POST /api/chat`, `POST /api/generate`. Tests skip gracefully if the configured model hasn't been pulled (Ollama returns 404 with a "not found" error).
* `cross_provider_integration_test.exs` — OpenAI source format is forwarded to a randomly selected target provider and the response is converted back to OpenAI format. Requires both OpenAI and Anthropic configured.

### Required env vars

Each provider file gates on the same `PROVIDER_*` env vars that production uses:

| Provider   | Required env vars                                                          |
|------------|----------------------------------------------------------------------------|
| OpenAI     | `PROVIDER_OPENAI_1_ENABLED=true`, `PROVIDER_OPENAI_1_API_KEY=sk-...`       |
| Anthropic  | `PROVIDER_ANTHROPIC_1_ENABLED=true`, `PROVIDER_ANTHROPIC_1_API_KEY=sk-ant-...` |
| Ollama     | `PROVIDER_OLLAMA_1_ENABLED=true` (and a reachable Ollama base URL)          |
| Cross-provider | Both OpenAI and Anthropic env vars above                               |

The base URL can be overridden per-provider via `PROVIDER_OPENAI_1_BASE_URL` etc.

### Optional env vars

* `INTEGRATION_TEST_MODEL` — override the default test model (e.g. `gpt-4o-mini` for OpenAI, `claude-3-5-haiku-latest` for Anthropic, `llama3.2` for Ollama). Set this to use a different model than the cheap default.

### Cost and CI notes

These tests hit real paid APIs by default. Don't run them in shared CI on every commit — gate them behind a manual workflow, schedule, or your own local env. The default models are chosen to be cheap (e.g. `gpt-4o-mini`, `claude-3-5-haiku-latest`), but a full integration suite still costs real money.

