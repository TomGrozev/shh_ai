# 05 — Type the per-chunk stream accumulator

## Problem

`build_initial_metrics/1` constructs an 8-key untyped `metrics_context` map whose keys span three different lifecycles—per-request, per-chunk, and per-finalization—mashed into one shape. `Metrics.emit_stream_stop/5` accesses 13 fields from this untyped map (8 from `metrics_context` + 5 from `StreamContext`), every access is a runtime guess with no compile-time validation, and a field rename in `StreamContext` ripples into 3 files. The interface is the test surface, and an untyped map is no interface at all—it is leakage across the seam that violates locality.

## Decision

Replace the untyped `metrics_context` map with a typed `ShhAi.ProviderClient.StreamHandler.Accumulator` struct. The struct carries only the per-chunk state (2 fields) and lives in `StreamHandler`—the module that mutates it every chunk, per Candidate 3's extracted lifecycle. Per-request values stay in the `StreamContext` per-request half (Candidate 3's design tree, item 2). `conversation_id` is passed in by `ProviderClient` at finalization, not held in the accumulator. Locality of mutation wins: the type lives where it is written, not where it is read once. `Metrics` depends on `StreamHandler`'s types, not the other way around; the struct crossing from `StreamHandler` to `Metrics` is a typed contract, not an untyped map.

## Design tree (resolved)

1. **Struct scope: per-chunk state only.** `restore_duration` (running total) and `assistant_content_chunks` (list of binaries). Per-request and per-finalization values are not carried.

2. **Struct lives in `StreamHandler`, not `Metrics`.** Defined as `ShhAi.ProviderClient.StreamHandler.Accumulator`. Mutated dominantly in `StreamHandler.handle_chunk/3`; read once at finalization by `Metrics.emit_stream_stop/5`.

3. **Constructor: `new/0` returns the empty accumulator.** `%Accumulator{restore_duration: 0, assistant_content_chunks: []}`. `StreamHandler.init/1` builds it and embeds it in the per-request handle.

4. **Mutation: struct update via field replacement.** `%{accumulator | restore_duration: accumulator.restore_duration + dur}`—immutable, typed. No more `Map.update!` on untyped keys.

5. **`Metrics.emit_stream_stop/5` takes typed arguments.** The accumulator is `%Accumulator{}`; per-request values are a typed spec from `StreamContext`. `conversation_id` (a plain string) is passed as the 4th arg and `assistant_content` (a pre-joined binary, computed by `StreamHandler.finalize/2`) is passed as the 5th arg. Field access is compile-time checked; no more `metrics_context.metrics_opts[:source_provider]` guessing.

6. **No ADR needed.** This is a deepening of an existing module and a typed-contract change. Future explorers would not re-litigate "should the per-chunk state be typed"—the type system enforces it.

## Lifecycle separation

| Original `metrics_context` key | Lifecycle | New home |
|---|---|---|
| `start_time` | Per-request | `RequestContext.started.monotonic` (see `04-request-context.md`) |
| `metrics_opts` | Per-request | `RequestContext` fields read directly by `Metrics.emit_stream_stop/6` (v2) |
| `pii_info` | Per-request | `RequestContext.pii_info` |
| `method` | Per-request | `RequestContext.method` |
| `source_path` | Per-request | `RequestContext.source_path` |
| `restore_duration` | Per-chunk | `Accumulator` struct |
| `assistant_content_chunks` | Per-chunk | `Accumulator` struct |
| `conversation_id` | Per-finalization | Passed by `ProviderClient` at finalization |

## Module shape

```
  StreamHandler.handle_chunk/3
         │
         │  %{accumulator | restore_duration: ...}
         │  %{accumulator | assistant_content_chunks: [...]}
         ▼
  ┌─────────────────────┐
  │    %Accumulator{}   │  ← typed struct (2 fields)
  │  restore_duration   │     mutated every chunk
  │  assistant_content  │
  │  _chunks            │
  └──────────┬──────────┘
             │
             │  on %SSEEvent{type: :done}
             │  StreamHandler wakes Metrics
             │
             ▼
  ┌──────────────────────────────────┐
  │  Metrics.emit_stream_stop/6      │  ← read-side consumer
  │    accumulator :: %Accumulator{} │     typed contract at the seam
  │    ctx         :: %RequestContext{}│     per-request static state (v2)
  └──────────────────────────────────┘

     The struct crosses the seam from StreamHandler to Metrics.
     The type IS the contract—no untyped map, no runtime guessing.
```

## Files affected

- `lib/shh_ai/provider_client/stream_handler.ex` — new struct `Accumulator` with `new/0`; `handle_chunk/3` mutates via struct update; finalization passes typed accumulator to `Metrics`.
- `lib/shh_ai/metrics.ex` — `emit_stream_stop/6` signature accepts `%StreamHandler.Accumulator{}` and per-request state from `%RequestContext{}` (v2: `RequestMeta` eliminated; per-finalization values read from `ctx` directly). 13 untyped field accesses become compile-time-checked struct field reads.
- `lib/shh_ai/provider_client.ex` — `build_initial_metrics/1` removed; `handle_stream_chunk/4` (moved to `StreamHandler` per Candidate 3) stops building the untyped map; `finalize_stream/3` passes typed accumulator.

## Tests

- Per-chunk accumulator tests live in `test/shh_ai/provider_client/stream_handler_test.exs` alongside Candidate 3's tests. Tests construct an accumulator via `Accumulator.new/0`, feed chunks through `handle_chunk/3`, and assert typed field values—the interface is the test surface.
- `emit_stream_stop/5` tests in `test/shh_ai/metrics_test.exs` construct a typed `%Accumulator{}` directly instead of building a map with the right keys. No more guessing whether `:restore_duration` or `:restore_time` is the correct key name—the compiler catches it.
- `build_initial_metrics/1` tests become waste; no replacement needed.

## Cross-reference

This candidate is a dependency of Candidate 3 (`03-streaming-handler.md`)—the deepened `StreamHandler` expects the typed `Accumulator` struct to exist, and Candidate 3's design tree (item 2) reserved the per-chunk accumulator slot that this candidate fills.

## Out of scope

- Per-finalization values (`conversation_id`) are passed in at finalization—not held in the struct.
- No ADR needed—this is a typed-contract deepening, not a decision future explorers would re-litigate.
- `build_initial_metrics/1` disappears as part of this work.

## Status

> Status: Resolved — implemented in issues #15, #17, #21. Typed `%StreamHandler.Accumulator{}` (per-chunk state) replaces the untyped `metrics_context` map. `build_initial_metrics/1` and `Req.Response` private-field stash removed. `Metrics.emit_stream_stop/6` takes typed args. As of issue #21, the per-request static state lives in `ShhAi.ProviderClient.RequestContext{}` (shared with the non-streaming request path), nested in `%StreamHandler.Handle{}`. **v2:** `RequestMeta` eliminated; per-finalization values read from `RequestContext` directly + bare `backend_start` integer. See `04-request-context.md`.
