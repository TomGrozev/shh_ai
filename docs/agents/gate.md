# Gate

One repo-owned command to run before yielding a change:

    mix precommit

`mix precommit` is a `mix` alias. It runs, in order:

1. `compile --warnings-as-errors`
2. `deps.unlock --unused`
3. `format`
4. `credo --strict`
5. `test`

The `pre-commit` hook runs the same alias as a backstop (installed via `git_hooks`, configured in `config/config.exs`), so commits are checked even when the gate isn't run by hand. `implement` and `walkthrough` still run it explicitly, because the work is uncommitted when it is reviewed and the output is the evidence.

CI runs the same checks on pull requests and pushes to `master` (`.github/workflows/ci.yaml`), using `format --check-formatted` since CI must not rewrite files.

## Toolchain

The project is pinned to Elixir 1.19.4 / OTP 28 (ADR 0015) — `.tool-versions` and `.devcontainer/devcontainer.json`. A newer Elixir refuses to load the project. In this sandbox the pinned toolchain lives at `/home/dev/tools/elixir-1.19.4/bin`; run the gate as

    PATH=/home/dev/tools/elixir-1.19.4/bin:$PATH mix precommit
