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

The project requires Elixir 1.19.4 or newer on OTP 28, with no upper bound (ADR 0017). CI uses the current release, Elixir 1.20.3. Install that toolchain in the usual way for your environment, then run the gate as usual:

    mix precommit
