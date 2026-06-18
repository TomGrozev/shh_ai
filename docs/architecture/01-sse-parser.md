# 01 — Deepen SSEParser

## Problem

Five SSE parsers with four different return shapes—tuples, maps, strings, and lists—are scattered across four modules. The interface is nearly as complex as the implementation: each call site couples to a specific parser's shape, and a change to the SSE wire format ripples into `PIIPipeline`, `Shared`, and multiple converters simultaneously. `PIIPipeline` owns split-placeholder buffering that is coupled to SSE frame structure rather than PII semantics—a leakage across the seam that violates locality.

## Decision

Deepen the existing `ShhAi.ProviderClient.SSEParser` into a single, wire-format-only module. Its sole public interface is `parse/1`, which accepts raw bytes and returns a list of typed `%SSEEvent{}` structs (see CONTEXT.md "SSEEvent"). The seam sits between SSEParser and the `ApiConverter` adapters: converters call `SSEParser.parse/1` and receive structured events; provider-specific event handling (e.g., Anthropic's `content_block_delta`) stays on the converter side.

## Design tree (resolved)

1. **Return shape**: `%SSEEvent{type: :data | :done | :event, ...}`—atomic type field. `event_name` only present for `type: :event`. `payload` only present for `type: :data`. `:done` is a stream-termination marker with no payload.

2. **SSEParser scope**: Wire format only. Bytes → list of typed events. No text extraction. No OpenAI message extraction. No provider-specific handling.

3. **Converter role**: Each `ApiConverter` adapter (OpenAI, Anthropic, Ollama) calls `SSEParser.parse/1` and returns a list of typed events from its `to_openai_stream_chunk/2` and `from_openai_stream_chunk/2` callbacks. The converter earns its keep by handling provider-specific event quirks (e.g., Anthropic's `content_block_delta`).

4. **Split-placeholder buffering**: Stays in `PIIPipeline`. It is a PII concern (placeholders are PII artefacts), not a wire-format concern. SSEParser never has to know what a placeholder is.

5. **SSEParser's other public functions**: `extract_content_from_openai_chunks/1` and `extract_assistant_message/1` move out—they are OpenAI-specific, not SSE-specific. Destination is `PIIPipeline` or a new `CanonicalFormat` module, to be decided at implementation time. `decode_sse_data/1` becomes a private helper.

6. **`Shared.parse_sse_chunk/1`**: Deleted. Anthropic and Ollama converters call `SSEParser.parse/1` directly.

## Module shape

```
             ┌───────────────┐
             │  Bytes from   │
             │   provider    │
             └───────┬───────┘
                     │
                     ▼
          ┌────────────────────────────┐
          │         SSEParser          │  ← wire-format only
          │  parse/1 → [%SSEEvent{}]   │     seam
          └─────────────┬──────────────┘
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
┌────────────┐ ┌────────────┐ ┌────────────┐
│  OpenAI    │ │ Anthropic  │ │  Ollama    │  ← ApiConverter adapters
│ Converter  │ │ Converter  │ │ Converter  │     provider-specific quirks
└─────┬──────┘ └─────┬──────┘ └─────┬──────┘
      └───────────────┼──────────────┘
                      │
                      ▼
           ┌─────────────────────┐
           │    PII Pipeline     │  ← split-placeholder buffering
           │ (text extraction,   │     text extraction
           │  sanitize/restore)  │
           └─────────────────────┘
```

## Files affected

- `lib/shh_ai/provider_client/sse_parser.ex` — deepened: new `parse/1` returning `[%SSEEvent{}]`; `extract_content_from_openai_chunks/1`, `extract_assistant_message/1` removed; `decode_sse_data/1` made private; `parse_sse_chunk_to_map/1` deleted.
- `lib/shh_ai/pii_pipeline.ex` — private `parse_sse_chunk/1` removed; split-placeholder buffering retained; text extraction added (or deferred to `CanonicalFormat`).
- `lib/shh_ai/api_converter/shared.ex` — `parse_sse_chunk/1` removed; call sites replaced with `SSEParser.parse/1`.
- `lib/shh_ai/api_converter/openai.ex` — private `parse_sse_chunk/1` removed; converter calls `SSEParser.parse/1` and handles `:done` → `:data` translation internally.
- `lib/shh_ai/api_converter/anthropic.ex` — calls `SSEParser.parse/1` instead of `Shared.parse_sse_chunk/1`; `content_block_delta` handling stays.
- `lib/shh_ai/api_converter/ollama.ex` — same change as Anthropic.

## Tests

- SSE-block tests in `test/shh_ai/pii_pipeline_test.exs` move to `test/shh_ai/provider_client/sse_parser_test.exs`—the interface is the test surface.
- `test/shh_ai/api_converter/shared_test.exs` SSE-parsing tests become waste; replaced by tests that verify converters call `SSEParser.parse/1` and handle returned `%SSEEvent{}` structs correctly.
- New tests at the deepened interface: `parse/1` with complete SSE frames, partial chunks, malformed frames, multiple events in one byte buffer, and the `[DONE]` marker. No provider-specific payloads—those belong in converter tests.

## Out of scope

- Destination for text extraction (`extract_content_from_openai_chunks/1`, `extract_assistant_message/1`)—deferred to implementation; `PIIPipeline` or a new `CanonicalFormat` module are both valid.
- `build_event/1` companion function on the `%SSEEvent{}` struct—to be decided at implementation time.
- No ADR needed—this is a deepening of an existing module, not a decision future explorers would re-litigate.

## Status

Resolved. Ready for implementation.
