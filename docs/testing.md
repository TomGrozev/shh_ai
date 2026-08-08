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

## Testing Strategy & Dev Loop

### The Testing Pyramid

The suite is shaped as a pyramid: many fast focused unit tests at the base, fewer medium-speed integration tests in the middle, a small number of slow high-confidence end-to-end tests at the top. Each layer is gated by an ExUnit tag and excluded from the default `mix test` run unless explicitly opted in.

```
            E2E (real LLM providers, 4 files)        ← `:integration` tag, never in default run
          Integration (in-repo, 6 files)             ← run by default
        Unit (1001+ tests, ~50s)                       ← the default `mix test` bed
```

### Test Slices (tags)

`test/test_helper.exs` excludes the following tags from the default run:

| Tag | What it covers | Files |
|-----|----------------|------|
| `:performance` | Benchee benchmarks (5s per scenario) | `test/performance/*_perf_test.exs`, `streaming_bench_test.exs` |
| `:stress` | Extreme payload sizes (100KB–1MB) — local-only, not for CI | `test/performance/stress_test.exs` |
| `:integration` | End-to-end against real LLM provider backends (costs real money) | `test/integration/*_integration_test.exs` |
| `:redis` | Requires a running Redis instance | `test/shh_ai/conversation/store/redis_test.exs` |
| `:slow` | Reserved for genuinely slow tests; currently unused | — |
| `:ner` | NER-model-dependent tests (load the BERT-small model) | `test/shh_ai/pii/ner_test.exs` |

To run a tagged slice, opt in:

```
mix test --only ner
mix test --only integration
mix test --only performance
```

### NER Model & Test Speed

The PII detector runs in `:complementary` mode by default — regex + NER (BERT-small via Bumblebee) — and `Config.load/0` calls `NER.init/0` whenever `PII_NER_ENABLED` is truthy (its default is `true`). If NER is loaded in the test env, every `Detector.detect/2` call in the regex detector tests pays 1–4 seconds of BERT inference, blowing the unit-test bed from ~10s to ~110s.

`config/test.exs` sets `PII_NER_ENABLED=false` to keep NER unloaded during `mix test`. NER-dependent tests live in `test/shh_ai/pii/ner_test.exs` (`@moduletag :ner`, excluded by default) and call `NER.init/0` in their own setup, so they are unaffected by the env-var setting. Run them explicitly with `mix test --only ner`.

Cost: ~1–2s of overhead per NER test run for model load. Worth it for the `:ner` slice; never worth it in the default suite.

### Dev Loop Commands

The 5-minute wait people associate with `mix test` comes from running the whole suite on every change. Almost never necessary. Use these instead:

| Command | When to use | Expected time |
|---------|-------------|---------------|
| `mix test test/path/to/changed_file_test.exs` | After editing one file — run just that file's tests | seconds |
| `mix test test/path/to/changed_file_test.exs:LINE` | One failing test at a specific line | sub-second |
| `mix test --stale` | Pre-commit sanity check — only re-runs tests whose compiled dependencies changed | seconds to low tens |
| `mix test` | Full default suite — the slowest thing you'd normally run, but still all unit tests | ~50s |
| `mix test --only ner` | Verify NER-model behaviour | ~10s |
| `mix test --only integration` | Verify against real LLM backends — costs real money | minutes |

### async: false — When and Why

31 test files are `async: false` by deliberate choice, not by accident. The codebase relies heavily on `:persistent_term` (via `Config.load/0`), shared named ETS tables (`:conversations`, `:conversation_mappings`, etc.), and application-supervised singletons (`ShhAi.Repo`, `ShhAi.Audit.Writer`, `ShhAi.Audit.Vault`) — all BEAM-global state that parallel tests would race on.

`async: false` is **required** for any test that:
- Calls `Config.load/0` (writes `:persistent_term`)
- Touches shared named ETS via `ConversationCase.setup_ets/0`
- Restarts `ShhAi.Repo` via `Supervisor.terminate_child/restart_child`
- Uses `:meck.new/2` to stub shared modules (the unload is global)
- Mutates env vars (`System.put_env`) that other tests read

`async: true` is safe only for tests whose setup is entirely process-local: `start_supervised!` children, test-unique telemetry handler IDs, or per-test-owned ETS. Currently only `test/shh_ai/metrics/emit_stream_stop_test.exs` and `test/shh_ai/metrics/event_buffer_test.exs` qualify.

Do not flip other files to `async: true` without first removing the shared-state dependency — premature flipping will introduce intermittent failures that are very hard to diagnose.

