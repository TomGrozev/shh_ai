# Track current Elixir, with an open upper bound

## Status

Accepted _(2026-10-05)_ — replaces the exact-Elixir-1.19.4 pin carried by `mix.exs` and the docs (which forbade Elixir 1.20).

## Context

`mix.exs` declares the supported Elixir toolchain via `elixir:` and the repo gate is `mix precommit`. The project was pinned to exactly Elixir 1.19.4, so Elixir 1.20 refused to load the project. Elixir 1.20's type checker also flagged several provably-dead clauses in the codebase; those were removed or rewritten so the gate is warning-free on 1.20.

The app ships as a **self-contained Docker image that pins the runtime**, so the project itself has no reason to defend against running on a newer Elixir — there is no user-supplied interpreter to mismatch. Maintaining an exact or two-minor support window is unnecessary cost.

## Decision

The `mix.exs` requirement is **`>= 1.19.4` — a minimum, with no upper bound.** 1.19.4 is simply the oldest release the code is known to compile on; any newer Elixir is accepted. CI and the deployment image use the current release (1.20.3 at the time of writing), and are the single source of truth for what actually ships.

## Consequences

### Positive

- The project loads on current Elixir (1.20.x) and on any future 1.x release without a `mix.exs` change.
- One CI job on the shipping toolchain, not a multi-version matrix.

### Negative

- `mix.exs` no longer warns when a developer runs an Elixir newer than CI has validated; the floor only catches *older* releases.
- The declared CI version still needs a manual bump when a new Elixir is adopted.

### Neutral

- The deployment image pins the runtime; `mix.exs` is only a developer-convenience guard.
