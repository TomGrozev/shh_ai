defmodule ShhAi.ApiConverter.OpenAI do
  @moduledoc """
  OpenAI API format converter.
  OpenAI format is the canonical intermediate format, so this module
  mostly passes through data unchanged.
  """

  @behaviour ShhAi.ApiConverter

  # OpenAI format is canonical - pass through

  @impl true
  def to_openai_request(headers, body, _path), do: {headers, body}

  @impl true
  def from_openai_request(headers, body, _path), do: {headers, body}

  @impl true
  def to_openai_response(response, _path), do: response

  @impl true
  def from_openai_response(response, _path), do: response

  @impl true
  def to_openai_stream_chunk(chunk, _path), do: [chunk]

  @impl true
  def from_openai_stream_chunk(chunk, _path), do: [chunk]

  @impl true
  def to_openai_path(path), do: path

  @impl true
  def from_openai_path(path), do: path

  @impl true
  def get_path_type("/v1/chat/completions"), do: {:chat, "/v1/chat/completions"}
  def get_path_type("/v1/completions"), do: {:chat, "/v1/completions"}
  def get_path_type("/v1/embeddings"), do: {:embeddings, "/v1/embeddings"}
  def get_path_type("/v1/models"), do: {:models, "/v1/models"}
  def get_path_type(path), do: {:other, path}
end
