Check ./CONTEXT.md for terminology questions.

## Agent skills

### Issue tracker

GitHub Issues — uses the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

Indexed as **shh_ai**. If stale: `npx gitnexus analyze`.

## Workflow

| Phase | GitNexus call | Purpose |
|-------|--------------|---------|
| Before editing a symbol | `gitnexus_impact({target, direction: "upstream"})` | Blast radius — warn user if HIGH/CRITICAL |
| Before committing | `gitnexus_detect_changes()` | Verify only expected symbols changed |
| Exploring unknown code | `gitnexus_query({query: "..."})` | Find execution flows (prefer over grep) |
| Full symbol context | `gitnexus_context({name: "..."})` | Callers, callees, process membership |
| Renaming a symbol | `gitnexus_rename({symbol_name, new_name})` | Graph-aware rename (never sed/replace) |

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/shh_ai/context` | Overview, index freshness |
| `gitnexus://repo/shh_ai/clusters` | Functional areas |
| `gitnexus://repo/shh_ai/processes` | Execution flows |
| `gitnexus://repo/shh_ai/process/{name}` | Step-by-step trace |
<!-- gitnexus:end -->
