# Configuration Reference

Every environment variable ShhAi reads, hand-maintained against the shipped
code. [`ShhAi.Config`](../lib/shh_ai/config.ex) is the source of truth: it is
loaded once at application start (`ShhAi.Application.start/2` calls
`ShhAi.Config.load/0`) and stores every value in `:persistent_term`, so
configuration is fixed for the lifetime of the running node — changes require
a restart.

Copy `.env.example` to `.env` and fill it in; `docker compose` reads it
automatically. For container-specific mechanics (images, volumes, the
`SHHAI_SLIM` build flag) see the deployment guide; for pointing coding
harnesses at the proxy see [Integrations](integrations.md).

## Parsing rules

How `ShhAi.Config` reads each variable — the same rules apply throughout this
page:

- **boolean**: unset → default; the literal `true` → true; the literal
  `false` → false; **anything else → default** (so `PHX_SERVER=false` does not
  disable the server — see the Server section for that presence-check case).
- **integer / float**: unset → default; a malformed value **crashes boot**.
- **CSV**: unset → default; otherwise comma-split and mapped per item.
- **enum**: unset → default; a recognised value is used; an unrecognised value
  silently falls back to the default.
- **Audit & model-catalog overrides**: an explicit application-environment
  override wins over the env var, which wins over the default. This is how
  test config overrides values without touching the process environment.

## Server / Deployment

| Variable | Type | Default | Required |
|---|---|---|---|
| `PHX_SERVER` | presence | absent | Never |
| `PORT` | integer | `4000` | Never |
| `SECRET_KEY_BASE` | string | — | **Yes, in prod** |
| `PHX_HOST` | string | `example.com` | Never |
| `DNS_CLUSTER_QUERY` | string | unset | Only when clustered |

- **`PHX_SERVER`** — if set *at all* (in `config/runtime.exs`), forces
  `server: true` on `ShhAiWeb.Endpoint`. It is a presence check, not a
  boolean: even `PHX_SERVER=false` enables the HTTP server. Production
  releases need it to serve HTTP (`bin/server` sets it; the container image
  sets it too).
- **`PORT`** — HTTP port of `ShhAiWeb.Endpoint`. In prod the endpoint URL is
  additionally pinned to `https`/443 for URL generation; the actual listener
  always binds `PORT` on all interfaces.
- **`SECRET_KEY_BASE`** — signs/encrypts cookies. Boot **raises** in prod when
  missing (`mix phx.gen.secret` generates one). It also seeds the
  per-deployment namespace UUID for the conversation fingerprinter
  (`UUID.uuid5(:dns, ...)`), so conversation IDs are unique to the deployment.
- **`PHX_HOST`** — host used in generated URLs (behind your TLS-terminating
  reverse proxy).
- **`DNS_CLUSTER_QUERY`** — DNS query for `DNSCluster` node discovery. Leave
  unset for single-node deployments (the child is then not started).

## Inbound Gate (Proxy Security)

| Variable | Type | Default | Required |
|---|---|---|---|
| `PROXY_API_KEYS` | comma-separated strings | `[]` | Boot never fails; required to serve `/v1` and `/api` |

- **`PROXY_API_KEYS`** — the bearer keys clients present to ShhAi
  (`Authorization: Bearer <key>`). Entries are comma-split and trimmed; blank
  entries are rejected at split time. **Fail closed**: while the list is
  empty, the `ShhAiWeb.ProxyAuth` gate refuses *every* `/v1` and `/api`
  request with `503`, and a loud warning is logged once per boot. Revoke a
  client by removing its key from the list.
- These are gate credentials only — the real provider keys live in the
  `PROVIDER_*` variables below and never appear in harness configuration (see
  [Integrations](integrations.md#authentication)).

## Providers (upstream LLM backends)

Pattern: `PROVIDER_<TYPE>_<N>_<FIELD>` where `<TYPE>` is `openai`,
`anthropic`, or `ollama` and `<N>` is `1..4` — up to four instances of each
type. A provider instance with `ENABLED` unset or not exactly `"true"`
contributes nothing and needs nothing.

| Variable | Type | Default | Required |
|---|---|---|---|
| `PROVIDER_<TYPE>_<N>_ENABLED` | literal `"true"` | unset (disabled) | Never |
| `PROVIDER_<TYPE>_<N>_API_KEY` | string | unset | **Yes** when enabled |
| `PROVIDER_<TYPE>_<N>_BASE_URL` | URL | see below | Never |
| `PROVIDER_<TYPE>_<N>_TIMEOUT` | integer (ms) | see below | Never |
| `PROVIDER_<TYPE>_<N>_NAME` | string | generated | Never |

- **`_ENABLED`** — exact string match on `"true"`; `TRUE`, `1`, or `yes` do
  **not** enable the instance.
- **`_API_KEY`** — upstream credential. Every *enabled* instance must carry a
  non-empty key; otherwise boot **raises**, e.g.
  `"PROVIDER_OPENAI_1_API_KEY is required: the enabled provider openai_1 has
  no API key..."`. (Ollama follows the same rule even where an upstream key is
  nominally optional — the config error names the exact variable to set or
  the `_ENABLED=false` escape.)
- **`_BASE_URL`** defaults: OpenAI `https://api.openai.com/v1`, Anthropic
  `https://api.anthropic.com`, Ollama `http://localhost:11434`.
- **`_TIMEOUT`** defaults: 60000 ms for OpenAI/Anthropic, 120000 ms for
  Ollama. Malformed integers crash boot.
- **`_NAME`** — optional display name; when unset, `ShhAi.ProviderName`
  generates the stable ADR-0013 instance name (`provider_index`, e.g.
  `openai_1`). Conversations pin this name, and `ShhAi.ModelCatalog` indexes
  instances under it.

## PII Detection

| Variable | Type | Default | Required |
|---|---|---|---|
| `PII_ENABLED` | boolean | `true` | Never |
| `PII_ERROR_MODE` | enum (`forward`) | `block` | Never |
| `PII_TYPES` | CSV of type atoms | all 16 core types | Never |
| `PII_REGEX_CONFIDENCE_THRESHOLD` | float | `0.8` | Never |
| `PII_PRESERVE_IN_SYSTEM` | CSV of type atoms | `location,organization,date` | Never |
| `PII_ALWAYS_SANITIZE` | CSV of type atoms | `ssn,financial,email,phone,api_key,secret,auth_token,private_key,medical_id,national_id` | Never |
| `PII_NER_ENABLED` | boolean | `true` in the full image, `false` in the slim image | Set `false` to boot without the NER model |
| `PII_NER_CONFIDENCE_THRESHOLD` | float | `0.60` | Never |
| `PII_NER_TYPE_THRESHOLDS` | CSV of `type:threshold` pairs | empty | Never |
| `PII_NER_TEMPERATURE` | float | `1.0` | Never |
| `PII_NER_MODEL` | HF repo id or local path | `gravitee-io/bert-small-pii-detection` | Never |
| `PII_NER_MODEL_REVISION` | string | unset (latest) | Never |
| `PII_HYBRID_MODE` | enum (`ner_only`, `regex_only`) | `complementary` | Never |

- **`PII_ENABLED`** — master switch for sanitisation.
- **`PII_ERROR_MODE`** — fail policy when a detector hard-errors (ADR-0014).
  The default `block` **fails closed**: the request is refused rather than
  forwarded unsanitised. Only the literal `forward` opts into **fail open**
  (forwarding un-sanitised content); unset, `block`, and any unrecognised
  value all stay on `block`. See the threat model for the tradeoff.
- **`PII_TYPES`** — categories to detect. Allowed atoms: `name`, `location`,
  `email`, `phone`, `ssn`, `financial`, `date`, `medical_id`, `ip_address`,
  `url`, `api_key`, `secret`, `auth_token`, `private_key`, `national_id`,
  `device_id`, `passport`, `organization`, `age`, `title`. Unknown entries
  are silently filtered out. Defaults cover the 16 core types.
- **`PII_REGEX_CONFIDENCE_THRESHOLD` / `PII_NER_CONFIDENCE_THRESHOLD`** —
  minimum confidence for regex / NER matches respectively. Malformed floats
  crash boot.
- **`PII_PRESERVE_IN_SYSTEM`** — PII types left untouched inside system
  messages (system prompts often legitimately contain such context).
- **`PII_ALWAYS_SANITIZE`** — types redacted regardless of message context.
- **`PII_NER_ENABLED`** — enables the neural (Bumblebee BERT-small) detector
  on top of regex. The full image bakes the model in and defaults this to
  `true`; the **slim image has no ML stack and defaults to `false`**
  (regex-only). With NER enabled, a model that fails to load **aborts boot**
  (crash-loop by design, ADR-0014/#65 — never serve with detection silently
  degraded). The operator escape hatch is `PII_NER_ENABLED=false`.
- **`PII_NER_MODEL`** — which NER model to load: a HuggingFace repo id, or a
  local directory path (a value starting with `/` or `.`). Defaults to the
  shipped `gravitee-io/bert-small-pii-detection`; a fine-tuned replacement
  (see [training/README.md](../training/README.md) and
  [ADR-0018](adr/0018-fine-tuned-pii-ner-model.md)) swaps in without a code
  change. A local path loads via Bumblebee's `{:local, dir}`; anything else is
  fetched from HuggingFace. The fine-tuned model emits BIO labels named after
  the uppercase supported PII types, so it needs no label remapping.
- **`PII_NER_MODEL_REVISION`** — pins the HuggingFace revision (git ref) when
  `PII_NER_MODEL` is a repo id; unset means latest. Ignored for local paths.
  Read together with `PII_NER_MODEL` by the Docker build (build args keep the
  baked-in cache and the runtime request on the same model).
- **`PII_HYBRID_MODE`** — detector combination: `complementary` (both
  detectors), or exactly one of `ner_only` / `regex_only`. Unrecognised
  values fall back to `complementary`.
- **`PII_NER_TYPE_THRESHOLDS`** — per-type confidence floors overriding
  `PII_NER_CONFIDENCE_THRESHOLD` for the listed NER types, e.g.
  `title:0.4,date:0.5`. Comma-separated `type:threshold` pairs; unlisted
  types keep the global threshold. Empty by default, so behaviour is
  unchanged unless set. Fail closed at boot: an entry with an unsupported
  PII type or a non-numeric threshold raises rather than being silently
  dropped.
- **Per-type thresholds file (`pii_thresholds.json`)** — a fine-tuned model
  (see [training/README.md](../training/README.md)) ships a
  `pii_thresholds.json` next to its weights, holding one threshold per PII
  type, searched per type on the training dev set. The runtime loads it at
  boot from the local model directory or, for a repo id, from the HuggingFace
  repo at `PII_NER_MODEL_REVISION` (same revision, cache dir and
  `BUMBLEBEE_OFFLINE` setting as the model files). Precedence is
  `PII_NER_TYPE_THRESHOLDS` > the model's file >
  `PII_NER_CONFIDENCE_THRESHOLD`. A missing file changes nothing; an invalid
  file (bad JSON, unknown type, out-of-range value) fails boot, per
  [ADR-0014](adr/0014-detector-failure-fail-closed-policy.md). A `0.0` entry
  keeps every entity the model's argmax produced.
- **`PII_NER_TEMPERATURE`** — confidence calibration for the NER detector;
  values > 1.0 reduce overconfidence. Defaults `1.0` (no rescaling) with a
  threshold of `0.60`: the previous combination (temperature 1.5 before a 0.85
  cutoff) effectively demanded a raw score of about 0.93 and silently dropped
  most NER matches. See the [benchmarks doc](benchmarks.md#ner-threshold) for
  how 0.60 was chosen.

### Offline NER model (container images)

`BUMBLEBEE_OFFLINE` and `BUMBLEBEE_CACHE_DIR` are **not read by application
code** — they are consumed by the Bumblebee/Nx library itself. ShhAi's
container images set them so the NER model is baked into the image at build
time and loaded air-gapped at runtime:

- **`BUMBLEBEE_CACHE_DIR`** — directory holding the pre-fetched model
  (`/models` in the image, populated during the Docker build).
- **`BUMBLEBEE_OFFLINE`** — `true` in the runtime image so Bumblebee loads
  from the local cache and never fetches over the network.

Set both only when running the full image outside the provided container; the
slim image (`SHHAI_SLIM=true` build flag) drops the ML stack entirely and
needs neither.

### Baking a different NER model into the image

The Docker build bakes exactly the model the runtime will load: the
`PII_NER_MODEL` / `PII_NER_MODEL_REVISION` build args (defaults:
`gravitee-io/bert-small-pii-detection`, empty revision) pre-fetch that model
into `BUMBLEBEE_CACHE_DIR` during the build **and** are passed through to the
runtime environment, so a build-arg/runtime mismatch cannot happen. To ship a
fine-tune (see [ADR-0018](adr/0018-fine-tuned-pii-ner-model.md)):

```sh
docker build \
  --build-arg PII_NER_MODEL=acme/shh-ai-pii-ner \
  --build-arg PII_NER_MODEL_REVISION=v1.0.0 \
  -t shh-ai:ner .
```

CI derives its Bumblebee cache key from the same two values (workflow-level
env in `.github/workflows/ci.yaml`), so changing either rebuilds the model
cache.

## Audit Mode

| Variable | Type | Default | Required |
|---|---|---|---|
| `AUDIT_MODE` | boolean | `false` | Never |
| `AUDIT_ENCRYPTION_KEY` | Base32 (32 bytes decoded) | unset | **Yes when `AUDIT_MODE=true`** |
| `AUDIT_RETENTION_DAYS` | integer (days) | `30` | Never |
| `AUDIT_CLEANUP_INTERVAL_HOURS` | integer (hours) | `1` | Never |
| `AUDIT_DB_PATH` | filesystem path | `priv/audit/audit.db` | Point at a mounted volume in prod |

- **`AUDIT_MODE`** — enables the persisted, encrypted audit store (ADR-0010,
  ADR-0016): starts the SQLite `ShhAi.Repo` and `ShhAi.Audit.Vault` children,
  and turns `bin/migrate` into a real migration run (the container entrypoint
  applies migrations only when this is on). Off by default — with Audit Mode
  off, no audit data is written anywhere.
- **`AUDIT_ENCRYPTION_KEY`** — AES-256-GCM key for the encrypted audit
  columns. **Fail closed at boot** when `AUDIT_MODE=true`: empty, invalid
  Base32, or a key that does not decode to exactly 32 bytes all raise with a
  message naming the fix. Generate one with:

  ```sh
  mix run -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode32())'
  ```

- **`AUDIT_RETENTION_DAYS`** — retention window for the audit cleanup job.
- **`AUDIT_CLEANUP_INTERVAL_HOURS`** — how often the cleanup job runs.
- **`AUDIT_DB_PATH`** — location of the audit SQLite database (WAL mode).
  Read twice: it overrides `ShhAi.Repo`'s `database:` config in
  `config/runtime.exs` *and* is stored via `ShhAi.Config`. In containers,
  point it at a mounted volume (e.g. `/data/audit.db`) so records survive
  restarts.

## Admin Dashboard

| Variable | Type | Default | Required |
|---|---|---|---|
| `ADMIN_USER` | string | `admin` | Never |
| `ADMIN_PASSWORD` | string | unset | **Yes, to use the dashboard at all** |

- **`ADMIN_USER`** — dashboard username; unset or empty falls back to
  `admin`.
- **`ADMIN_PASSWORD`** — dashboard credential. Fail closed: unset or empty
  means the dashboard is *not configured* — every `/admin` route returns
  `403` — and a loud warning is logged once per boot.

## Conversation Store

| Variable | Type | Default | Required |
|---|---|---|---|
| `CONVERSATION_STORE_BACKEND` | enum (`redis`) | `ets` | Never |
| `CONVERSATION_TTL` | integer (ms) | `3600000` (1 h) | Never |
| `REDIS_URL` | URL string | unset | When backend is `redis` |

- **`CONVERSATION_STORE_BACKEND`** — backend for `ShhAi.Conversation.Store`
  (ADR-0004). Only the literal `redis` selects Redis; anything else —
  including unset, `ets`, or a typo — runs the in-memory ETS backend. Note
  ETS is per-node and wiped on restart.
- **`CONVERSATION_TTL`** — how long an idle conversation is retained
  (refreshed on every request). Malformed integers crash boot.
- **`REDIS_URL`** — Redis connection string. No boot validation: a bad URL
  surfaces as a client connect failure at runtime.

## Model Catalog

| Variable | Type | Default | Required |
|---|---|---|---|
| `MODEL_CATALOG_REFRESH_INTERVAL_MS` | integer (ms) | `300000` (5 min) | Never |

- **`MODEL_CATALOG_REFRESH_INTERVAL_MS`** — how often `ShhAi.ModelCatalog`
  re-probes every enabled provider instance. Malformed integers crash boot.

## Metrics

| Variable | Type | Default | Required |
|---|---|---|---|
| `METRICS_BUFFER_SIZE` | integer | `1000` | Never |

- **`METRICS_BUFFER_SIZE`** — size of the ETS ring buffer holding recent
  metric events. Unlike everything above, this is **not** read through
  `ShhAi.Config` — `ShhAi.Metrics.EventBuffer` reads it lazily at first use,
  so a malformed value crashes at read time rather than at boot.

## See also

- [Integrations](integrations.md) — pointing coding harnesses at the proxy
  with a base-URL change and the gate key.
- `docs/architecture/` and `docs/adr/` — design decisions behind the gate
  (ADR-0013), the PII fail policy (ADR-0014), the audit store (ADR-0010,
  ADR-0016), and configuration-via-persistent-term (ADR-0006).
- `.env.example` — a copyable template mirroring this reference (kept in sync
  by `test/shh_ai/deployment_test.exs`).
