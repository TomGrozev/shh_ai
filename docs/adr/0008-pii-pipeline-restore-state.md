# RestoreState struct lives in PIIPipeline, not StreamHandler

## Status

Accepted _(Phase 2 of the ProviderClient cleanup, 2026-06-21)_

## Context

During the #13–#21 architecture deepening, the PII pipeline's streaming
state was held as an untyped map `%{buffer: binary()}` threaded through
`ShhAi.PIIPipeline.restore_stream_chunk/3` and
`ShhAi.PIIPipeline.restore_stream_events/4`. The map's only field was
`:buffer` — the split-placeholder buffer that accumulates a partial
placeholder across chunks. The state was held in
`ShhAi.ProviderClient.StreamHandler.Handle.pii_state` and read/written
exclusively by `ShhAi.PIIPipeline`.

Phase 2 of the ProviderClient cleanup (see
`docs/architecture/06-providerclient-flow-review.md` finding I) promoted
this state to a typed struct. Two possible homes were considered:

1. **`ShhAi.ProviderClient.StreamHandler.PiiState`** — next to the
   `Handle` struct that holds it.
2. **`ShhAi.PIIPipeline.RestoreState`** — next to the module that
   constructs, reads, and writes the state.

The split-placeholder buffer is an internal detail of the PII pipeline's
restore algorithm: it exists because `<PERSON_1>` may be split across a
chunk boundary, and the pipeline needs to remember the partial text so
the next chunk can complete the placeholder. The buffer is never
inspected by `StreamHandler` — the Handle just holds the value and
threads it back into the next call to `restore_stream_*`. The
`StreamHandler` is a pass-through container; the PII pipeline is the
consumer that owns the algorithm.

## Decision

The `%PIIPipeline.RestoreState{}` struct lives in the `PIIPipeline`
namespace, not in `StreamHandler`.

- **Struct definitions live with their consumer, not their container.**
  `RestoreState` is the PII pipeline's internal state. `StreamHandler`
  is just a pass-through holder. The buffer's meaning is defined by
  `PIIPipeline`; `StreamHandler` has nothing to add to the
  definition.
- **The `@enforce_keys [:buffer]` + `new/0` pattern applies.** This
  mirrors `ShhAi.ProviderClient.StreamHandler.Accumulator` and the
  other typed-state structs introduced during the deepening. The
  struct lives at `lib/shh_ai/pii_pipeline/restore_state.ex` as
  `ShhAi.PIIPipeline.RestoreState`. `new/0` returns
  `%__MODULE__{buffer: ""}` — the initial state before any chunks
  have been processed.
- **The `StreamHandler.Handle.pii_state` field type is now
  `RestoreState.t()`** — a typed reference, not a bare map. The Handle
  aliases the struct and threads it through unchanged.

## Consequences

### Positive

- **The type lives where the semantics live.** The split-placeholder
  buffer is encapsulated by the module that owns the algorithm. A
  reader of `PIIPipeline.restore_stream_chunk/3` or
  `PIIPipeline.restore_stream_events/4` finds the struct definition
  in the same namespace as the function that uses it.
- **Consistent with the other typed-state structs.** `Accumulator` and
  `RequestContext` are similarly placed: each struct lives with the
  module that defines its semantics, and the `Handle`/`ProviderClient`
  aliases the type.
- **Compile-time field checking.** Once the field access is
  `state.buffer` (struct field) instead of `Map.get(state, :buffer,
  "")` (map access), typos become compile errors.

### Negative

- **A reader following `Handle.pii_state` to `StreamHandler` will not
  find the struct definition there.** They must follow the alias to
  `ShhAi.PIIPipeline.RestoreState`. This is acceptable because the
  struct is small (one field) and the import chain is shallow (one
  alias hop in `StreamHandler`).
- **The alias chain is one step deeper than placing the struct in
  `StreamHandler`.** Negligible in practice — the Handle already
  aliases `RestoreState` for its own type spec.

### Neutral

- **Future streaming-state structs follow the same rule.** If a new
  piece of state is needed (e.g. an Anthropic event-type cache), the
  struct lives with the consumer that owns the algorithm. The Handle
  continues to be a pass-through container, and `StreamHandler` does
  not grow a `StreamHandler.*State` namespace.
- **The `new/0` constructor pattern is reused.** Mirroring
  `Accumulator.new()`, `RestoreState.new()` is the only way to
  construct the initial state — no `defstruct` defaults can construct
  a fresh struct across modules, so the explicit constructor is the
  established pattern.
