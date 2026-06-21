# `:raw` sentinel for converters that don't model the wire format as SSE events

## Status

Accepted _(Phase 2 of the ProviderClient cleanup, 2026-06-21; amended
by the Phase 3 final cleanup, 2026-06-21 — the `_chunk` callback pair
is removed from the behaviour, and Ollama's `from_openai_stream_events/2`
becomes a real events-in/NDJSON-out implementation)_

## Context

The `ShhAi.ApiConverter` behaviour declared two streaming-callback
pairs:

- **`to_openai_stream_chunk/2` + `from_openai_stream_chunk/2`** —
  bytes-in, bytes-out. The target-side callback parses the raw wire
  bytes, classifies each frame, re-serialises to OpenAI-format SSE
  lines, and returns them. The source-side callback does the inverse
  (parses OpenAI-format bytes, classifies, re-serialises to the source
  wire format).
- **`to_openai_stream_events/2` + `from_openai_stream_events/2`** —
  bytes-in, typed-events-out. Added by issues #14 and #16 to avoid
  double-parsing: the target-side callback parses the wire bytes once
  and hands back the typed `%SSEParser{}` frames so the caller
  (`StreamHandler`) can re-use the same events when restoring PII and
  extracting content.

After the deepening, `to_openai_stream_events/2`'s return type was
`[SSEParser.t()] | :done | {:error, term()}`. Ollama's implementation
returned `[]` always, because Ollama's wire format is **newline-delimited
JSON**, not SSE — it does not model the format as typed events at all.

`StreamHandler.convert_and_restore_stream_chunk/7` used `[]` as a
sentinel to dispatch to the `convert_via_chunks` fallback. This was
**ambiguous**: `[]` could mean

1. "no complete frame in this chunk" — a partial-frame case that is
   normal and expected (the next chunk will complete the frame); or
2. "this converter doesn't speak events" — a fallback signal for
   Ollama's JSON-per-line format.

The two cases had to be disambiguated by inspecting the wire format
heuristically, which is fragile and not testable in isolation.

## Decision

`to_openai_stream_events/2` returns `[SSEParser.t()] | :done | :raw | {:error, term()}`.

- **`:raw` is the explicit "I don't model this wire format as events"
  signal.** Only Ollama returns it today. The caller
  (`StreamHandler`) dispatches to the chunk-based fallback path
  (`convert_via_chunks`) which re-parses the bytes via the target's
  plain `to_openai_stream_chunk/2` function (Ollama is the only
  production converter that ships a `to_openai_stream_chunk/2` plain
  function) and proceeds with the events path uniformly.
- **`[]` (empty list) means "parsed successfully but no complete
  events in this chunk"** — a genuine partial-frame case, not a
  dispatch trigger. The caller waits for the next chunk to complete
  the frame. This is the same semantics the behaviour has had since
  #16; the `:raw` addition does not change it.
- **The asymmetry is the point.** Ollama returns `:raw`; OpenAI and
  Anthropic return typed events. The converter's capability is now an
  **explicit, testable claim**, not an implicit emergent property of
  the empty-list case.
- **`from_openai_stream_events/2` is a real events-in /
  source-bytes-out callback for every converter**, including Ollama.
  Ollama's wire format is NDJSON (newline-delimited JSON) — it
  cannot be parsed as SSE events on the input side, but on the
  output side the conversion from OpenAI events to NDJSON bytes does
  not require SSE parsing either. Ollama's `from_openai_stream_events/2`
  walks each event's payload and feeds it to the existing
  `handle_openai_stream_event/2` private helper, which produces
  NDJSON lines (using `message` for `/api/chat` and `response` for
  `/api/generate`).

### Per-direction asymmetry

The asymmetry between input and output for Ollama is a **per-direction
property**, not a per-converter property. Input is bytes-only (NDJSON
→ can't parse as SSE). Output is events-only (OpenAI events → NDJSON
bytes, no SSE parsing needed). This is cleaner than the previous
"Ollama is fully bytes-shaped" framing because it avoids the
double-work of re-serializing events to bytes and re-parsing them in
the source-conversion path: the events produced by
`to_openai_stream_events/2` (when not `:raw`) and the restored events
from the PII pipeline can be fed straight to
`from_openai_stream_events/2` for any source converter, including
Ollama.

## Consequences

### Positive

- **Dispatch is typed, not list-length-driven.** The fallback path is
  a single explicit `case :raw -> ...` arm, not a list-length
  heuristic. Future code readers see the two cases
  (`:raw` for fallback, `[]` for partial frame) without
  having to reverse-engineer the heuristic.
- **The fallback path is uniform with the hot path.** Even when the
  target returns `:raw` (Ollama), the bytes that come back from
  `to_openai_stream_chunk/2` (Ollama's plain function) are
  OpenAI-format SSE chunks; those chunks are then re-parsed to typed
  events and fed through `process_chunks_with_events/5` — the same
  events-in / events-out pipeline as the hot path. Only the very
  first step (parsing the wire format) is different, and that
  difference is unavoidable (NDJSON can't be parsed as SSE).
- **Future converters that don't speak events can opt in by
  returning `:raw` from `to_openai_stream_events/2` only.** The
  source direction (`from_openai_stream_events/2`) doesn't need a
  corresponding `:raw` — a hypothetical binary-streaming provider
  whose events shape can't be expressed as `%SSEParser{}` can
  implement the events path on the output side and just have its
  target-side events classification produce events the existing
  per-converter classify-and-serialise code can handle.
- **The behaviour contract is honest about converter capabilities.**
  Before the sentinel, the contract implied "all converters can
  produce events" (modulo a hidden fallback). The sentinel makes the
  fallback an explicit feature, not a workaround.

### Negative

- **The behaviour contract grows a fourth return value on
  `to_openai_stream_events/2`.** It must now be pattern-matched on
  `:done`, `:raw`, `{:error, _}`, and `events_or_chunks` — one more
  case than before. All callers (`StreamHandler`, the converter
  tests) need to handle the new case. `from_openai_stream_events/2`
  no longer returns `:raw` (no production converter needs it), so
  its return set is `[String.t()] | :done | {:done, [String.t()]} |
  {:error, term()}`.
- **The Ollama converter's `to_openai_stream_events/2` stub must be
  intentionally inert.** The implementation `def
  to_openai_stream_events(_chunk, _path), do: :raw` looks like dead
  code, but it is the explicit declaration of "I don't model this
  format as events." A reader who removes it as "unused" would
  silently break the fallback path. The comment block above the
  implementation explains this.
- **Ollama's `to_openai_stream_chunk/2` is a plain function, not a
  behaviour callback.** The behaviour contract is now events-only;
  the bytes-shaped input path is a private implementation detail
  of the Ollama module. A reader who expects the bytes-shaped pair
  to be discoverable through the behaviour will be surprised — the
  `ShhAi.ApiConverter` behaviour docs explain that
  `to_openai_stream_events/2` returning `:raw` means "fall back to
  the target's plain `to_openai_stream_chunk/2` function (Ollama
  only)."

### Neutral

- **The `_chunk` callback pair is removed from the behaviour.** The
  legacy bytes-shaped pair was kept on the behaviour while some
  converters couldn't speak events — that asymmetry is gone now.
  Ollama's `to_openai_stream_chunk/2` is a plain function (the only
  plain function on a converter module that exists for the
  streaming contract) and is called by name from
  `StreamHandler.convert_via_chunks/6` when the target returns
  `:raw`.
- **The asymmetry between Ollama (`to_openai_stream_events/2`
  returns `:raw`; has a plain `to_openai_stream_chunk/2` function)
  and OpenAI / Anthropic (events-only) is the point, not a bug.**
  It communicates which converters model the wire format as events
  and which do not. A future converter that handles a non-SSE wire
  format would follow the same pattern as Ollama (return `:raw`
  from `to_openai_stream_events/2`, ship a plain
  `to_openai_stream_chunk/2` function).
