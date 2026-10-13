# Installation

ShhAi 0.1.0 ships two ways: as a **Docker image** (recommended — the runtime,
NER model, and build toolchain are pinned for you) or **from source** with a
local Elixir/OTP toolchain. Both paths run the same application; configuration
is environment-only either way (see `docs/configuration.md`).

## Prerequisites (both paths)

ShhAi needs at least one configured LLM backend and an inbound proxy key to be
useful:

- `PROXY_API_KEYS` — comma-separated bearer keys clients present to ShhAi.
  While unset, the proxy refuses every `/v1` and `/api` request with **503**
  (fail-closed); boot still succeeds with a loud warning.
- At least one provider instance enabled, e.g. `PROVIDER_ANTHROPIC_1_ENABLED=true`
  with a non-empty `PROVIDER_ANTHROPIC_1_API_KEY` — an enabled instance without
  a key is a **boot-time config error**.

`SECRET_KEY_BASE` is required in production (generate with `mix phx.gen.secret`).
The full variable reference, with defaults and types, lives in
`docs/configuration.md`; the checked-in `.env.example` is a ready-to-edit
template covering every group (server, gate, backends, PII, Audit Mode,
dashboard, conversation store, metrics).

---

## Option A: Docker (recommended)

The single `Dockerfile` produces one of two tags, selected by the
`SHHAI_SLIM` build flag:

| Tag | Contents | PII detection |
|---|---|---|
| `full` (default) | EXLA + Nx + Bumblebee, with the NER model baked into `/models` and loaded offline | Regex + neural (BERT NER) |
| `slim` | ML stack dropped; boots with `PII_NER_ENABLED` off | Regex only |

### Run with Compose

The checked-in `docker-compose.yml` wires everything together — rootless
(`USER nonroot`, uid 65532), `read_only: true` root filesystem, `no-new-privileges`,
`/tmp` as tmpfs, and an `audit-data` volume mounted at `/data`:

1. Copy and fill in the environment:

   ```sh
   cp .env.example .env
   # set at minimum: SECRET_KEY_BASE, PROXY_API_KEYS, and one provider
   ```

2. Build and start:

   ```sh
   docker compose up --build          # full image
   SHHAI_SLIM=true docker compose up --build   # regex-only image
   ```

   The image tag defaults to `shh-ai:0.1.0` (override with `SHHAI_TAG`).
   The published port is `PORT`, default `4000`.

3. Verify:

   ```sh
   curl http://localhost:4000/health
   curl http://localhost:4000/ready
   ```

   `/ready` reports `not_ready` until the NER model has loaded (full image
   only; slim has no NER check).

**Audit Mode** is opt-in: set `AUDIT_MODE=true` in `.env`. The container
entrypoint then applies database migrations via `bin/migrate` before the
proxy starts (a no-op when Audit Mode is off), and the encrypted SQLite audit
DB is written to the `audit-data` volume.

**`AUDIT_DB_PATH` and persistence:** the compose file mounts the named volume
at `/data`, and `.env.example` sets `AUDIT_DB_PATH=/data/audit.db` so the
database survives container replacement. With Audit Mode off, `/data` stays
empty and no durable writes exist — `/tmp` (tmpfs) is the only writable path.
The `/data` directory is pre-created with `nonroot` ownership so a fresh named
volume is writable by the container user. If you change `AUDIT_DB_PATH`, point
it inside a mounted volume or the container (whose root filesystem is
read-only) will fail to create the database.

**Rootless / read-only constraints** (relevant if you run the image without
compose or with a different runtime):

- The container runs as Wolfi's `nonroot` user (uid 65532); never expect to
  write outside `/tmp` and the mounted audit volume.
- The root filesystem is read-only-friendly: `HOME`, `TMPDIR`, and the release
  tmp dir are all redirected to `/tmp`, and `RELEASE_DISTRIBUTION=none`.
- Bind-mount any external audit volume with `:rw` and matching ownership for
  uid 65532.

**Running the image directly** (no compose) — the entrypoint handles migration
on Audit Mode automatically:

```sh
docker run --read-only --tmpfs /tmp --user 65532 \
  --env-file .env -p 4000:4000 \
  -v shh-ai-audit:/data \
  shh-ai:0.1.0
```

---

## Option B: From source

### Toolchain

- **Elixir `>= 1.19.4` with OTP 28** (ADR 0017 tracks current Elixir with an
  open upper bound; 1.19.4 is the floor, newer releases are accepted).
- Erlang/OTP headers and build tools for the native NIFs (`build-base`-equivalent:
  a C compiler, `openssl-dev`, `ncurses-dev`, `zlib-dev`), plus `git`.
- The full (non-slim) profile additionally downloads and compiles EXLA at
  `mix deps.compile`, which needs a working C++ toolchain (`libstdc++`, `libgcc`).

### Build

```sh
mix local.hex --force && mix local.rebar --force
mix deps.get          # mix.lock pins every dependency
mix assets.setup      # installs tailwind + esbuild
mix deps.compile      # EXLA compile included (full profile)
mix assets.deploy     # minified assets + phx.digest
mix release           # self-contained release in _build/prod/rel/shh_ai
```

To build the regex-only profile from source, export `SHHAI_SLIM=true` before
`mix deps.get`/`mix deps.compile` — the ML dependencies (`nx`, `exla`,
`bumblebee`) are then omitted and the release boots with NER off.

### Run

Production releases must enable the HTTP server explicitly:

```sh
PHX_SERVER=true PORT=4000 \
SECRET_KEY_BASE=$(mix phx.gen.secret) \
PROXY_API_KEYS=<your-key> \
PROVIDER_ANTHROPIC_1_ENABLED=true \
PROVIDER_ANTHROPIC_1_API_KEY=sk-ant-... \
_build/prod/rel/shh_ai/bin/shh_ai start
```

`PHX_SERVER` is a presence check (any value, including `false`, enables the
server). Generated `bin/server` sets it for you.

**Audit Mode from source:** set `AUDIT_MODE=true` and
`AUDIT_ENCRYPTION_KEY` (Base32; generate with
`mix run -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode32())'`).
`AUDIT_DB_PATH` defaults to `priv/audit/audit.db`; in production point it at
durable storage. Run migrations with
`_build/prod/rel/shh_ai/bin/migrate` (a no-op when Audit Mode is off).

---

## Next steps

- Configure coding harnesses to point at the proxy: `docs/integrations.md`.
- Full environment-variable reference: `docs/configuration.md`.
- What the proxy does and does not protect: `docs/privacy.md`.
- Detection quality and latency numbers: `docs/benchmarks.md`.
