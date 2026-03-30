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
  Convert a streaming chunk from the target format to OpenAI format.
  Returns a list of OpenAI-compatible SSE lines.
  """
  @callback to_openai_stream_chunk(stream_chunk(), target_path :: String.t()) ::
              [String.t()] | :done | {:done, [String.t()]} | {:error, term()}

  @doc """
  Convert a streaming chunk from OpenAI format to the source format.
  Returns a list of source-format SSE lines.
  """
  @callback from_openai_stream_chunk(stream_chunk(), source_path :: String.t()) ::
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
