# 03 — Deepen streaming: extract StreamHandler

## Problem

Streaming logic consumes 2/3 of `ProviderClient`'s 584 lines, threaded through a 17-field `StreamContext` struct that crosses module boundaries: `ProviderClient` populates it, `StreamTransport` reads `into:` callback wiring from it, Req private fields carry state between invocations, and `handle_stream_chunk/4` mutates it per chunk. To trace a single streaming chunk, you read 5 functions across 3 modules—a seam leak that violates locality. `handle_stream_chunk/4` is a public function with only one call site, inside `StreamTransport`'s `into:` callback—the interface is the test surface, and it is the wrong surface.

## Decision

Extract a `StreamHandler` module that owns the streaming lifecycle end-to-end. `StreamContext` becomes internal—no other module constructs, reads, or mutates it. The seam sits between `StreamHandler` and `StreamTransport`: `StreamHandler` exposes `init/1` (returns an opaque handle) and `handle_chunk/3` (accepts the handle, a raw chunk, and the `Plug.Conn`; returns `{:cont, conn} | :halt`). `StreamTransport` becomes a Req I/O adapter—builds the request with the `into:` callback wired to `StreamHandler.handle_chunk/3`, executes it, and handles error-side metrics and `Conversation.touch`. Finalization triggers inside `handle_chunk/3` when Candidate 1's deepened `SSEParser` produces `%SSEEvent{type: :done}`.

## Design tree (resolved)

1. **StreamHandler owns the lifecycle**: `StreamContext`, the per-chunk callback, conversion/restoration pipeline, and finalization all live in `StreamHandler`. The 17-field struct becomes internal.

2. **Three concerns, three structs** (NOT one big struct): per-request state (static after `init`), per-chunk accumulator (mutated per chunk), per-finalization values (passed in at the end, not held across chunks).

3. **Interface**: Two public functions—`init/1` takes a per-request spec and returns an opaque handle; `handle_chunk/3` takes the handle, a raw chunk, and the `Plug.Conn`, returning `{:cont, conn} | :halt`. Finalization for the `[DONE]` event lives inside `handle_chunk/3`.

4. **StreamTransport shrinks to a Req adapter**: Keeps `build_stream_request/3` (wiring `into:` to `StreamHandler.handle_chunk/3`) and `do_stream/2` (executes the request, handles error-side metrics + `Conversation.touch`). The 7-arg `send_chunks_to_conn/7` becomes a private helper or moves into `StreamHandler`.

5. **`ProviderClient.handle_stream_chunk/4` becomes private (or deleted)**: After the deepening, no other module calls it. If it survives, it must be `@doc false` and only invoked from `ProviderClient`'s own code paths.

6. **`ProviderClient.stream/8` entry point stays**: It still constructs the spec and kicks off the stream, but delegates the streaming lifecycle to `StreamHandler.init/1` and chunk handling to `StreamHandler.handle_chunk/3` (via `StreamTransport`'s `into:` callback).

## Lifecycle separation

| Concern | Lifetime | Held by | Example fields |
|---|---|---|---|
| Per-request | Static after `init` | `RequestContext` (nested in Handle; shared with non-streaming path) | `source_provider`, `target_provider`, `source_path`, `target_path`, `method`, `config`, `source_converter`, `target_converter`, `conversation`, `openai_body`, `mapping`, `reverse_index`, `pii_info`, `timings`, `started` |
| Per-chunk | Mutated every chunk | Handle (top-level fields) | `conn` (SSE chunked response), `stream_fun`, `pii_state` buffer, `StreamHandler.Accumulator` (Candidate 5) |
| Per-finalization | Only at stream end | Read from `RequestContext` directly at finalization | `start_time`, `started_at`, `pii_info`, `pre_stream_timings`, `metrics_opts` → all from `ctx`; `backend_start` is a bare integer captured before `Req.request/1` |

The `Handle` struct composes the per-request static state (via the
nested `%RequestContext{}`) and the 4 streaming-only fields
(`conn`, `stream_fun`, `pii_state`, `accumulator`). It does NOT
carry per-finalization values — those are read from `RequestContext`
directly at finalization. `backend_start` is a bare integer captured
in `perform_stream/3` and threaded to `finalize/2`. See
`docs/architecture/04-request-context.md` for the design note on
`RequestContext`.

Finalization is a single `Metrics.emit_stream/1` call inside `handle_chunk/3` when `SSEParser` produces `%SSEEvent{type: :done}`. The per-finalization values are available from the per-request spec at that point; `StreamHandler` does not carry them across chunks.

## Module shape

```
                 ┌────────────────────┐
                 │   Bytes from       │
                 │   provider         │
                 └────────┬───────────┘
                          │
                          ▼
              ┌──────────────────────────┐
              │     StreamTransport      │  ← Req I/O adapter
              │  build_stream_request/3  │     builds `into:` wiring
              │  do_stream/2             │     error metrics + touch
              └────────────┬─────────────┘
                           │ Req `into:` callback
                           ▼
              ┌──────────────────────────┐
              │     StreamHandler        │  ← owns streaming lifecycle
              │  init/1 → handle         │
              │  handle_chunk/3          │     conversion/restoration
              └────────────┬─────────────┘     pipeline + finalization
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │ SSEParser│ │ PII      │ │ Metrics  │
        │(Cand. 1) │ │ Pipeline │ │ .emit_   │
        └──────────┘ └──────────┘ │ stream   │
                                  └──────────┘

   ProviderClient.stream/8  ──►  builds per-request spec
                                calls StreamHandler.init/1
                                kicks off through StreamTransport
```

## Files affected

- `lib/shh_ai/provider_client.ex` — `StreamContext` struct removed; `handle_stream_chunk/4` moved to `StreamHandler` or made private; `stream/8` entry point delegates to `StreamHandler.init/1`.
- `lib/shh_ai/provider_client/stream_transport.ex` — `send_chunks_to_conn/7` and `stream_chunks_to_conn/3` moved or deleted; `build_stream_request/3` wires `into:` to `StreamHandler.handle_chunk/3`; `do_stream/2` sheds `ctx`-based finalization (now owned by `StreamHandler`).
- `lib/shh_ai/provider_client/stream_handler.ex` — new module: `init/1`, `handle_chunk/3`, internal `StreamContext` struct, conversion/restoration pipeline, finalization.
- `test/shh_ai/provider_client/stream_handler_test.exs` — new file: chunk-callback tests for `handle_chunk/3` at the deepened interface.
- `test/shh_ai/provider_client_test.exs` — updated for the new entry point shape; integration tests may shift to `StreamHandler`-level tests.

## Tests

- Chunk-callback tests for `handle_chunk/3` live in a new `test/shh_ai/provider_client/stream_handler_test.exs`. Tests construct `StreamHandler` handles directly from canned per-request specs and feed raw chunks—no Req mock needed. The interface is the test surface.
- The existing integration tests in `test/shh_ai/provider_client_test.exs` may need updates for the new entry point shape (`stream/8` calling `StreamHandler.init/1`).
- `StreamTransport`'s `do_stream/2` error-handling path (metrics emission + `Conversation.touch`) is testable with a mocked `Req`—no `StreamHandler` involvement.
- Finalization logic (the `[DONE]` event triggering `Metrics.emit_stream`) is exercised through `handle_chunk/3` tests with canned `%SSEEvent{type: :done}` payloads from Candidate 1's deepened `SSEParser`.

## Out of scope

- Candidate 5 (`ShhAi.ProviderClient.StreamHandler.Accumulator` struct) — the per-chunk accumulator is defined in `docs/architecture/05-stream-accumulator.md`. The struct lives in StreamHandler, not Metrics, and carries typed per-chunk state (2 fields). Candidate 3's `StreamHandler` expects this struct to exist; the struct shape is specified in the separate design note.
- The `init/1` spec shape is deferred to implementation.
- No ADR needed—this is a deepening, not a decision future explorers would re-litigate.

## Status

> Status: Resolved — implemented in issues #15, #18, #20, #21. `StreamHandler` owns the streaming lifecycle via `init/1`, `handle_chunk/3`, `finalize/2`. `StreamTransport` reduced to a Req adapter exposing only `build_stream_request/3` and `do_stream/2`. Old `handle_stream_chunk/4` and `send_chunks_to_conn/7` removed. As of issue #21, the `Handle` struct composes a nested `%RequestContext{}` (per-request static, shared with the non-streaming request path) plus 4 streaming-only fields; the previous 13 flat per-request+per-chunk fields were consolidated. **v2:** `RequestMeta` eliminated; per-finalization values read from `RequestContext` directly + bare `backend_start` integer. See `docs/architecture/04-request-context.md` for the design note.
