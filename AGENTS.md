Check ./CONTEXT.md for terminology questions.

## Stack

Elixir 1.19.4 / OTP 28 with Phoenix 1.8 (pinned per ADR 0015). Stack packs: `rule://stack-elixir`, `rule://stack-phoenix`.

## Agent skills

### Issue tracker

GitHub Issues — uses the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Conventions

How code is written here. See `docs/agents/conventions.md`.

### Gate

The one command to run before yielding: `mix precommit`. See `docs/agents/gate.md`.
