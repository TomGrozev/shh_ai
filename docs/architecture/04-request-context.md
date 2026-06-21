# 04 — Share the post-preparation state between request and stream paths

## Problem

The post-preparation state of a single proxy request was repackaged
across five different data structures — eight awkward seams the same
typed information crossed:

1. The 8-tuple returned by `ProviderClient.prepare_request_context/7`:
   `{conversation, openai_body, mapping, reverse_index, pii_info,
   target_headers, target_body, timings}` — positional, no field
   names, easy to mis-order, hard to add a field to.
2. The 6-tuple `prep_context` re-packed at the HTTP call site in
   `request/6`: `{conversation, openai_body, mapping, reverse_index,
   pii_info, timings}` — even though `target_headers` and `target_body`
   are single-use at the HTTP site, the success/error handlers still
   re-receive all six values for the metrics emit.
3. Two 2-tuples (`{source_converter, source_path}` and
   `{target_converter, target_path}`) threaded into
   `handle_request_success/7` — a fourth positional seam to keep in
   sync with the rest.
4. The 11-key `ctx` map in `stream/8` and `execute_stream/2` — a
   parallel hierarchy to the 6-tuple above, with its own duplication of
   the same fields and a separate `target_path` value that the
   non-streaming path stored as a local.
5. The 9 duplicated fields on `%StreamHandler.Handle{}` —
   `source_converter`, `target_converter`, `source_path`,
   `source_provider`, `method`, `conversation`, `openai_body`,
   `mapping`, `reverse_index` — every per-request static value lived
   twice in the system, once on the streaming handle and once in
   the non-streaming tuple.

Tracing a single field through the request lifecycle meant reading
five call sites across three modules and matching by position
rather than name. Adding a per-request value (e.g. a new
`headers` field) required editing all five seams in lockstep.

## Decision

Introduce a single typed contract — `ShhAi.ProviderClient.RequestContext{}`
— that holds the 16 fields shared by both the request (non-streaming)
and stream paths. Both paths build one at the top of their entry
point (`request/6` and `stream/8`) and pass it forward. The streaming
path additionally nests the struct inside a `%StreamHandler.Handle{}`
for per-chunk state. The four consumer functions
(`handle_request_success/2`, `handle_request_error/2`,
`execute_stream/3`, `StreamHandler.handle_chunk/3`,
`StreamHandler.finalize/2`) all read off the same struct.

The struct is the "per-request static" concern — values that never
mutate during the request lifecycle. It pairs with:

  * `ShhAi.ProviderClient.StreamHandler.Accumulator` — per-chunk
    mutable state

Together these implement the "two concerns, two structs (plus Handle
as the composition)" design from `03-streaming-handler.md`, with this
struct additionally shared with the non-streaming request path. The
seam is a typed struct crossing the module boundary, not a tuple or
map. Per-finalization values (formerly `RequestMeta`) are read from
`RequestContext` directly; `backend_start` is captured as a bare
integer just before `Req.request/1` and threaded to `finalize/2`.

## What it replaces

1. The 8-tuple from `prepare_request_context/7` is now a private
   internal 8-tuple returned by `prepare_request_body/7` and consumed
   only by the two call sites in `request/6` and `stream/8`. It never
   crosses a module boundary — the public seam is the struct.
2. The 6-tuple `prep_context` re-pack at the HTTP call site is gone.
3. The two 2-tuples (`{source_converter, source_path}`,
   `{target_converter, target_path}`) are gone — `handle_request_success/2`
   reads them directly off the struct.
4. The 11-key `ctx` map in `stream/8` is gone — replaced by a single
   `%RequestContext{}` value. `execute_stream/3` is `(conn, stream_fun,
   ctx)`.
5. The 9 duplicated fields on `%StreamHandler.Handle{}` are gone —
   `Handle` is now 5 fields: `request_context` (nests the struct) plus
   4 streaming-only fields (`conn`, `stream_fun`, `pii_state`,
   `accumulator`).

`handle_request_success/7` becomes `handle_request_success/2`,
`handle_request_error/6` becomes `handle_request_error/2`,
`execute_stream/2` becomes `execute_stream/3` (with `(conn, stream_fun,
ctx)` as the new signature).

`target_headers` and `target_body` are HTTP single-use artifacts. They
are constructed in the call site and passed to `execute_stream/3` as a
2-tuple — they are NOT carried on the struct (which would widen its
purpose to include transient HTTP artefacts).

## Struct shape

```elixir
defmodule ShhAi.ProviderClient.RequestContext do
  @enforce_keys [
    :source_provider,    # :openai | :anthropic | :ollama
    :target_provider,    # :openai | :anthropic | :ollama (type atom for converter lookup)
    :source_path,        # e.g. "/v1/chat/completions"
    :target_path,        # resolved target path (cross-converter)
    :method,             # :get | :post | :put | :delete
    :config,             # provider config map (base_url, api_key, timeout, name)
    :source_converter,   # source ApiConverter module
    :target_converter,   # target ApiConverter module
    :conversation,       # %ShhAi.Conversation{}
    :openai_body,        # canonical (OpenAI-format) body, post-sanitize
    :mapping,            # %ShhAi.PII.SanitizationResult.mapping()
    :reverse_index,      # %ShhAi.PII.SanitizationResult.reverse_index()
    :pii_info,           # %ShhAi.PII.SanitizationResult.pii_info()
    :timings,            # pre-stream timings: pii + source + target conversion
    :started,            # %{monotonic: integer(), system: integer()}
    :streaming           # boolean() — is this a streaming request?
  ]
  defstruct @enforce_keys
end
```

`@enforce_keys` makes the struct impossible to construct without
every field — the compiler catches a missing field at the call site,
not at runtime when the missing field is finally read.

## Files affected

- `lib/shh_ai/provider_client/request_context.ex` — NEW. The struct.
- `lib/shh_ai/provider_client.ex` — `request/6` and `stream/8` both
  build a `%RequestContext{}` and pass it to the consumer functions.
  `handle_request_success/2` and `handle_request_error/2` are the
  new minimal signatures. `execute_stream/3(conn, stream_fun, ctx)`
  replaces `execute_stream/2(ctx, prep)`. `prepare_request_context/7`
  is renamed `prepare_request_body/7` and returns an internal 8-tuple
  that never crosses a module boundary.
- `lib/shh_ai/provider_client/stream_handler.ex` — `Handle` is now 5
  fields (was 13): nests `%RequestContext{}` plus 4 streaming-only
  fields. `handle_chunk/3` and `finalize/2` read per-request static
  state from `handle.request_context` instead of top-level handle
  fields.
- `test/shh_ai/provider_client/stream_handler_test.exs` — test
  fixtures build a `%RequestContext{}` and nest it. New "Handle
  struct shape" tests assert the 5-field shape and that
  `Handle.request_context` holds the per-request state.
- `test/shh_ai/provider_client/stream_transport_test.exs` — same
  fixture update.
- `test/shh_ai/provider_client_test.exs` — public-API tests pass
  unchanged (the public signatures of `request/6` and `stream/8` did
  not change).

## Tests

- `%RequestContext{}` is constructed with `@enforce_keys` — a missing
  field raises `ArgumentError` at construction time, not at the
  consumer. The "Handle struct shape" tests pin both the
  `Handle` field set and the `RequestContext` field set.
- The public APIs of `request/6` and `stream/8` are unchanged, so the
  integration tests in `test/shh_ai/provider_client_test.exs` pass
  unmodified. If a test fails after this refactor, the refactor has
  a bug — the contract is the public API.
- The `StreamHandler` tests build a fresh `%RequestContext{}` for
  each test (mirroring `ProviderClient.execute_stream/3`'s
  construction). The new `RequestContext has no per-finalization
  fields` test pins the lifecycle separation.
- The `:streaming` field is pinned by a new test in
  `provider_client_test.exs` that asserts the field is `true` on
  streaming paths and `false` on non-streaming (v2).

## Cross-references

- **`docs/architecture/03-streaming-handler.md`** — the lifecycle
  separation table now lists `RequestContext` as the per-request
  static concern (this struct was previously implicit in the
  `StreamContext` design). Per-finalization values are read from
  `RequestContext` directly; `RequestMeta` has been eliminated.
- **`docs/architecture/05-stream-accumulator.md`** — the
  `Accumulator` struct is unchanged. `RequestMeta` has been
  eliminated; per-finalization values now flow from
  `RequestContext` + a bare `backend_start` integer. Only the
  `Handle` shape is updated (now nests `RequestContext`).

## Decision v2 (Eliminate RequestMeta)

The original `RequestMeta` struct (introduced alongside `RequestContext`) was a
"per-finalization" wrapper around six values used only at stream end:
`start_time`, `started_at`, `backend_start`, `metrics_opts` (a 5-key map),
`pii_info`, `pre_stream_timings`. Five of these six were straight
copies of fields already on `RequestContext` (`start_time` ↔
`ctx.started.monotonic`, `started_at` ↔ `ctx.started.system`, `pii_info` ↔
`ctx.pii_info`, `pre_stream_timings` ↔ `ctx.timings`, and 4 of the 5
`metrics_opts` keys). Only `backend_start` was genuinely new — a monotonic
timestamp captured at the moment `Req.request/1` is called.

The struct was retired. `Metrics.emit_stream_stop/6` now takes
`(status, ctx, backend_start, acc, conversation_id, assistant_content)`
and reads per-finalization values from `ctx` directly. The `streaming`
flag is a first-class field on `RequestContext` (no more hardcoded
`streaming: false` in `default_success_opts/1`).

The `target_provider` naming collision is also resolved. `RequestContext.target_provider`
remains the type atom (`:openai | :anthropic | :ollama`); the instance
name (e.g., `"gpt-4"`) lives in `ctx.config.name` and is the single source
of truth emitted in metrics metadata. The two concepts are no longer
conflated under a shared field name.

Streaming state is now **two structs, not three**:

  * `%RequestContext{}` — per-request static state, shared with the
    non-streaming request path. The streaming flag is one of its fields.
  * `%StreamHandler.Accumulator{}` — per-chunk mutable state.
  * `%StreamHandler.Handle{}` — per-chunk wrapper; nests `RequestContext`
    and `Accumulator`.

`backend_start` is captured in `ProviderClient.perform_stream/3` as a
bare integer (no wrapper struct) and threaded through to `finalize/2`
and `do_stream/3`.

## Out of scope

- `target_headers` and `target_body` are HTTP single-use artefacts,
  passed as a 2-tuple at the call site. They are NOT added to the
  struct.
- No new structs beyond `RequestContext`.
- No ADR needed — this is a deepening of the existing `03-streaming-handler.md`
  design, not a new decision future explorers would re-litigate.

## Status

> Status: Resolved (v1) — implemented in issue #21. `ShhAi.ProviderClient.RequestContext{}`
> (15 fields) is the single typed contract for post-preparation state,
> shared by the request and stream paths. `Handle` reduced from 13 to
> 5 fields (nests `RequestContext` + 4 streaming-only fields). Five
> awkward seams (8-tuple, 6-tuple, two 2-tuples, 11-key map, 9
> duplicated Handle fields) eliminated.
>
> Status: Resolved (v2) — `RequestMeta` eliminated. `RequestContext` grew
> to 16 fields with the new `:streaming` boolean. Per-finalization values
> are read from `RequestContext` directly; `backend_start` is a bare integer
> captured before `Req.request/1`. `Metrics.emit_stream_stop/6` takes
> `(status, ctx, backend_start, acc, conversation_id, assistant_content)`.
> `target_provider` type atom vs. instance name collision resolved
> (`ctx.config.name` is the single source of truth for the provider
> instance name in metrics). Streaming state is now two structs, not three.
