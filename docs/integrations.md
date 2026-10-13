# Integrations

ShhAi sits in front of your LLM backends as a privacy proxy. Coding harnesses
point at it with **only a base-URL change** — no plugins, no per-harness
runtime code. Compatibility is proven at the dialect level by the endpoint-
organised conformance tests (`test/shh_ai_web/controllers/proxy_conformance_test.exs`):
adding a harness to this list is a documentation-only change.

## Base URL

Wherever ShhAi runs (`http://localhost:8080` below), it exposes two dialect
surfaces behind the inbound API-key gate (`PROXY_API_KEYS`):

| Dialect | Endpoint | Covered harnesses |
|---|---|---|
| OpenAI | `POST /v1/chat/completions` | opencode, OpenWebUI, Cline, Aider, Continue, Zed |
| Anthropic | `POST /v1/messages` | Claude Code |

Set the harness's base URL so its dialect path lands on the matching surface.
Most OpenAI-dialect tools already append `/chat/completions` (or `/v1/...`)
themselves — keep the base **up to but not including** the path ShhAi already
serves, i.e. `http://localhost:8080/v1` for OpenAI-style tools.

## Authentication

Every request must carry the proxy key from `PROXY_API_KEYS` as
`Authorization: Bearer <key>`. This is the **inbound gate**, not a passthrough:
your real backend keys are configured on the ShhAi side
(`PROVIDER_OPENAI_1_API_KEY`, `PROVIDER_ANTHROPIC_1_API_KEY`) and never appear
in a harness configuration.

## Harness configuration

### Claude Code (Anthropic dialect)

```sh
export ANTHROPIC_BASE_URL=http://localhost:8080
export ANTHROPIC_AUTH_TOKEN=<proxy-key>   # sent as: Authorization: Bearer <proxy-key>
```

Claude Code appends `/v1/messages` itself, so the base URL is the bare host.

### opencode (OpenAI dialect)

In `opencode.json` (or `~/.config/opencode/opencode.json`):

```json
{
  "provider": {
    "shhai": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://localhost:8080/v1",
        "apiKey": "<proxy-key>"
      }
    }
  }
}
```

### OpenWebUI (OpenAI dialect)

Admin → Settings → Connections → OpenAI API:

- **Base URL:** `http://localhost:8080/v1`
- **API key:** `<proxy-key>`

### Cline (OpenAI dialect)

In Cline settings, choose **OpenAI Compatible**:

- **Base URL:** `http://localhost:8080/v1`
- **API key:** `<proxy-key>`

### Aider (OpenAI dialect)

```sh
export OPENAI_API_BASE=http://localhost:8080/v1
export OPENAI_API_KEY=<proxy-key>

aider --model openai/gpt-4o
```

(Model name must be one served by a configured ShhAi backend.)

### Continue (OpenAI dialect)

In `~/.continue/config.yaml`:

```yaml
models:
  - name: ShhAi
    provider: openai
    apiBase: http://localhost:8080/v1
    apiKey: <proxy-key>
    model: gpt-4o
```

### Zed (OpenAI dialect)

In Zed's `settings.json`:

```json
{
  "language_models": {
    "openai_compatible": {
      "ShhAi": {
        "api_url": "http://localhost:8080/v1",
        "available_models": [
          {
            "name": "gpt-4o",
            "max_tokens": 128000,
            "max_output_tokens": 16384
          }
        ]
      }
    }
  }
}
```

Zed reads the key from the `SHHAI_API_KEY` environment variable — set it to the
proxy key.

## Backend configuration reminder

The harness key is only the gate credential. The real provider credentials
live in ShhAi's environment, e.g.:

```sh
PROXY_API_KEYS=<proxy-key>
PROVIDER_ANTHROPIC_1_ENABLED=true
PROVIDER_ANTHROPIC_1_API_KEY=sk-ant-...
PROVIDER_OPENAI_1_ENABLED=true
PROVIDER_OPENAI_1_API_KEY=sk-...
```

The security properties this split relies on — the fail-closed inbound
gate, the header allowlist that keeps your gate key away from backends,
and the fail policies around sanitization — are specified in
`docs/threat-model.md`.

See `docs/adr/` for the proxy architecture decisions and the README's
configuration section for the full env-var reference.
