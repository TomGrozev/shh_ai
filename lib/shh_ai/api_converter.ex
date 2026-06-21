defmodule ShhAi.ApiConverter do
  @moduledoc """
  Behaviour and utilities for converting between different LLM API formats.

  All converters convert to/from OpenAI format as the canonical intermediate format.
  This allows any source format to be converted to any target format.
  """

  @type provider :: :openai | :anthropic | :ollama
  @type request_headers :: [{String.t(), String.t()}]
  @type request_body :: map()
  @type response_body :: map() | String.t()
  @type stream_chunk :: String.t()

  @doc """
  Convert a request body from the source format to OpenAI format.
  """
  @callback to_openai_request(request_headers(), request_body(), source_path :: String.t()) ::
              {request_headers(), request_body()}

  @doc """
  Convert a request body from OpenAI format to the target format.
  """
  @callback from_openai_request(request_headers(), request_body(), target_path :: String.t()) ::
              {request_headers(), request_body()}

  @doc """
  Convert a response body from the target format to OpenAI format.
  """
  @callback to_openai_response(response_body(), target_path :: String.t()) :: response_body()

  @doc """
  Convert a response body from OpenAI format to the source format.
  """
  @callback from_openai_response(response_body(), source_path :: String.t()) :: response_body()

  @doc """
  Parse a streaming chunk from the target format into typed SSE events.

  This is the hot-path counterpart to the bytes-shaped
  `to_openai_stream_chunk/2` (which is no longer part of the
  behaviour, but is still shipped as a plain function on Ollama for
  its newline-delimited JSON fallback in
  `StreamHandler.convert_via_chunks/6`). It surfaces the
  already-parsed `%SSEParser{}` events so
  the caller (StreamHandler) can re-use them when re-encoding after
  PII restoration, avoiding a second `SSEParser.parse/1` per chunk.

  Returns one of:

    * a list of `%SSEParser{}` events (possibly empty for a partial frame
      that didn't complete in this chunk),
    * `:done` if the chunk carried a stream-termination marker,
    * `:raw` if the converter does not model this wire format as typed
      SSE events (e.g. Ollama's newline-delimited JSON). The caller
      falls back to the target converter's plain
      `to_openai_stream_chunk/2` function (Ollama is the only
      production converter that returns `:raw` and the only one that
      ships a `to_openai_stream_chunk/2` plain function),
    * `{:error, reason}` for parse failure.

  See `docs/adr/0009-converter-raw-sentinel.md` for the rationale
  behind the `:raw` sentinel.
  """
  @callback to_openai_stream_events(stream_chunk(), target_path :: String.t()) ::
              [SSEParser.t()] | :done | :raw | {:error, term()}

  @doc """
  Convert a list of pre-parsed `%SSEParser{}` events from OpenAI
  format to source-format wire bytes. Hot-path counterpart to the
  bytes-shaped `from_openai_stream_chunk/2` (no longer part of the
  behaviour; no converter ships it) — takes the already-parsed events
  (the same events produced by `to_openai_stream_events/2`) and
  serialises each one to the source wire format, avoiding a second
  parse per chunk on the hot path. Used by the events-in/events-out
  restore path.

  The path parameter tells the converter which source-format
  endpoint to emit (e.g. `/api/chat` vs `/api/generate` for Ollama)
  — the OpenAI events are canonical, but each source provider has
  its own wire shape and its own per-endpoint variations.

  Returns one of:

    * a list of source-format wire bytes (possibly empty if the
      events produced no output),
    * `:done` if the events included a stream-termination marker
      and the conversion is complete (some converters return
      `{:done, chunks}` instead — see the converter module for the
      exact shape),
    * `{:error, reason}` for any other failure.
  """
  @callback from_openai_stream_events([SSEParser.t()], source_path :: String.t()) ::
              [String.t()] | :done | {:done, [String.t()]} | {:error, term()}

  @doc """
  Convert a source provider path to OpenAI-equivalent path.
  """
  @callback to_openai_path(source_path :: String.t()) :: String.t()

  @doc """
  Convert an OpenAI path to the target provider path.
  """
  @callback from_openai_path(openai_path :: String.t()) :: String.t()

  @doc """
  Get the type of endpoint for a given path.
  """
  @callback get_path_type(path :: String.t()) ::
              {:chat, String.t()}
              | {:embeddings, String.t()}
              | {:models, String.t()}
              | {:other, String.t()}

  @doc """
  Returns the module that handles conversions for the given provider.
  """
  @spec get_converter(provider()) :: module()
  def get_converter(:openai), do: ShhAi.ApiConverter.OpenAI
  def get_converter(:anthropic), do: ShhAi.ApiConverter.Anthropic
  def get_converter(:ollama), do: ShhAi.ApiConverter.Ollama

  @doc """
  Get the target path for a given source path and target provider.
  Maps the endpoint to the equivalent endpoint for the target provider.
  """
  @spec get_target_path(String.t(), provider(), provider()) :: String.t()
  def get_target_path(source_path, source_provider, target_provider) do
    source_converter = get_converter(source_provider)
    target_converter = get_converter(target_provider)

    # Get the OpenAI-equivalent path, then convert to target
    openai_path = source_converter.to_openai_path(source_path)
    target_converter.from_openai_path(openai_path)
  end

  @doc """
  Get the path mapping for a given path and provider.
  """
  @spec get_path_info(String.t(), provider()) ::
          {:chat, String.t()}
          | {:embeddings, String.t()}
          | {:models, String.t()}
          | {:other, String.t()}
  def get_path_info(path, provider) do
    converter = get_converter(provider)
    converter.get_path_type(path)
  end
end
