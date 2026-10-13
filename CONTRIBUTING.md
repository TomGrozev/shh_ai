# Contributing

Thanks for your interest in ShhAi. This guide covers the local setup, the test
loop, the documentation conventions, and how a change gets merged.

## Prerequisites

- **Elixir 1.19.4 or newer** on **OTP 28** (ADR [0017](docs/adr/0017-track-current-elixir.md)).
  Newer releases are accepted; there is no upper bound. CI uses the current
  release, Elixir 1.20.3.

## Setup

```sh
git clone https://github.com/TomGrozev/shh_ai.git
cd shh_ai
mix deps.get
mix assets.setup   # install Tailwind and esbuild binaries (first run only)
```

`mix setup` runs `deps.get`, `assets.setup`, and `assets.build` in one step.

## The gate

Every change must pass the repo-owned gate before it is reviewed:

```sh
mix precommit
```

`mix precommit` runs, in order:

1. `compile --warnings-as-errors`
2. `deps.unlock --unused`
3. `format`
4. `credo --strict`

The `pre-commit` hook runs the same alias as a backstop (installed via
`git_hooks`), but run it by hand too — it is the evidence that a change is
ready. CI additionally runs `mix format --check-formatted` (CI must not rewrite
files) and `mix test`.

## Test loop

```sh
mix test                 # the default, fast suite
```

Heavy suites are gated behind ExUnit tags and excluded from the default run.
Opt in explicitly:

| Command                 | Covers                                                        |
| ----------------------- | ------------------------------------------------------------- |
| `mix test.integration`  | End-to-end proxy requests against real provider backends       |
| `mix test.performance`  | Benchee performance suites                                     |
| `mix test.stress`       | Stress suites                                                  |

Integration tests hit paid APIs and require the `PROVIDER_*` environment
variables (per provider). See [`docs/testing.md`](docs/testing.md) for the full
matrix, cost notes, and the PII test setup (`ShhAi.Config.load/0` plus
`ShhAi.PII.Patterns.load_into_persistent_term/0`).

Write tests first (red → green) and assert observable behaviour at an existing
seam — request/response shapes, routing outcomes, persisted or redacted values
— not internal wiring or source text.

## Conventions

- [`AGENTS.md`](AGENTS.md) — the entry point: stack, gate, and where each
  convention lives.
- [`CODING_STANDARDS.md`](CODING_STANDARDS.md) — how code is written here:
  data access, configuration, errors and logging, tests.
- [`GLOSSARY.md`](GLOSSARY.md) — the domain vocabulary. Use its terms; it lists
  the synonyms to avoid.

### ADRs

Architectural decisions live in [`docs/adr/`](docs/adr/) as numbered Markdown
files (`NNNN-slug.md`). When a change makes or reverses a decision, add a new
ADR rather than editing history, and link it from the code or doc it governs.
If a change contradicts an existing ADR, surface it in the PR.

### Agent docs

[`docs/agents/`](docs/agents/) holds the conventions that skills and agents
follow: the issue tracker (`issue-tracker.md`), triage labels
(`triage-labels.md`), and the domain-docs layout (`domain.md`). Update these
when a workflow changes, not the other way around.

## Pull requests

1. Branch from `master`.
2. Make the change; keep it scoped to one concern.
3. Run `mix precommit` and the relevant test suites.
4. Open a PR against `master` with a clear description of the change and why.
5. CI runs the gate's checks plus `mix test`; address failures before review.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, …) and describe the change,
not the session that produced it.

## Reporting bugs and security issues

Bugs and feature requests go to
[GitHub Issues](https://github.com/TomGrozev/shh_ai/issues). **Security issues
must not be filed as public issues** — see [`SECURITY.md`](SECURITY.md).
