Check ./GLOSSARY.md for terminology questions.

## Stack

Elixir 1.19.4+ / OTP 28 with Phoenix 1.8 (current: 1.20.3; ADR 0017). Stack packs: `rule://stack-elixir`, `rule://stack-phoenix`.

## Agent skills

### Issue tracker

GitHub Issues — uses the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — one `GLOSSARY.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Conventions

How code is written here. See `CODING_STANDARDS.md`.

## Gate

One repo-owned command to run before yielding a change:

    mix precommit

`mix precommit` is a `mix` alias. It runs, in order:

1. `compile --warnings-as-errors`
2. `deps.unlock --unused`
3. `format`
4. `credo --strict`

The `pre-commit` hook runs the same alias as a backstop (installed via `git_hooks`, configured in `config/config.exs`), so commits are checked even when the gate isn't run by hand. `implement` and `walkthrough` still run it explicitly, because the work is uncommitted when it is reviewed and the output is the evidence.

CI runs the gate's checks plus `mix test` on pull requests and pushes to `master` (`.github/workflows/ci.yaml`), using `format --check-formatted` since CI must not rewrite files.

A module-boundary check (`mix xref graph --format cycles --fail-above 0`) is deliberately **not** wired into the gate: four pre-existing compile-time cycles remain (the `api_converter` quartet; `config` ↔ `pii/ner`). Revisit if those cycles are broken.

## Toolchain

The project requires Elixir 1.19.4 or newer on OTP 28, with no upper bound (ADR 0017). CI uses the current release, Elixir 1.20.3. Install that toolchain in the usual way for your environment, then run the gate as usual:

    mix precommit
