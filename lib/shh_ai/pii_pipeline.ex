defmodule ShhAi.PIIPipeline do
  @moduledoc """
  PII sanitization pipeline that works exclusively in OpenAI (canonical) format.

  This module ensures all PII operations happen in a consistent format,
  regardless of the source or target provider format.

  ## Pipeline Flow

      Request (any format) → Convert to OpenAI → Sanitize → Convert to target
      Response (target) → Convert to OpenAI → Restore → Convert to source

  ## Responsibilities

  - Sanitize PII in OpenAI-format request bodies
  - Restore PII in OpenAI-format response bodies
  - Store and retrieve mappings via SessionStore
  """

  require Logger

  alias ShhAi.{SessionStore, PII}

  @type mapping :: %{String.t() => String.t()}

  @doc """
  Sanitize PII from an OpenAI-format request body.

  This function expects the body to already be in OpenAI format.
  It handles:
  - Chat completion requests with `messages` array
  - Other request types (pass-through with empty mapping)

  ## Options

    * `:session_id` - Session ID to store the mapping (optional)
    * `:enabled` - Whether PII sanitization is enabled (default: from config)

  ## Examples

      iex> body = %{"messages" => [%{"role" => "user", "content" => "My email is john@example.com"}]}
      iex> {:ok, sanitized, mapping} = ShhAi.PIIPipeline.sanitize_openai_request(body)
      iex> sanitized
      %{"messages" => [%{"role" => "user", "content" => "My email is <EMAIL_1>"}]}
      iex> mapping
      %{"EMAIL_1" => "john@example.com"}

  """
  @spec sanitize_openai_request(body :: map(), opts :: keyword()) ::
          {:ok, sanitized_body :: map(), mapping :: mapping()}
  def sanitize_openai_request(body, opts \\ []) do
    if pii_enabled?(opts) do
      do_sanitize_openai_request(body, opts)
    else
      {:ok, body, %{}}
    end
  end

  defp do_sanitize_openai_request(%{"messages" => messages} = body, opts)
       when is_list(messages) do
    sanitize_messages("messages", messages, body, opts)
  end

  defp do_sanitize_openai_request(%{"input" => messages} = body, opts)
       when is_list(messages) do
    sanitize_messages("input", messages, body, opts)
  end

  defp do_sanitize_openai_request(body, _opts) do
    # For non-message bodies (e.g., embeddings, moderations), sanitize the entire text
    json = Jason.encode!(body)
    {:ok, sanitized, mapping} = PII.Sanitizer.sanitize(json)

    case Jason.decode(sanitized) do
      {:ok, decoded} -> {:ok, decoded, mapping}
      {:error, _} -> {:ok, body, mapping}
    end
  end

  defp sanitize_messages(key, messages, body, opts) do
    case PII.Sanitizer.sanitize_messages(messages) do
      {:ok, sanitized_messages, mapping} ->
        sanitized_body = Map.put(body, key, sanitized_messages)

        # Store mapping if session_id provided
        maybe_store_mapping(opts[:session_id], mapping)

        {:ok, sanitized_body, mapping}

      {:error, reason} ->
        Logger.error("PII sanitization failed: #{inspect(reason)}")
        {:ok, body, %{}}
    end
  end

  @doc """
  Restore PII in an OpenAI-format response body.

  This function restores PII placeholders with their original values.
  It should be called after converting the response to OpenAI format.

  ## Options

    * `:session_id` - Session ID to retrieve the mapping from (optional)
    * `:mapping` - Explicit mapping to use (overrides session lookup)

  ## Examples

      iex> response = %{"choices" => [%{"message" => %{"content" => "Hello <PERSON_1>"}}]}
      iex> mapping = %{"PERSON_1" => "John"}
      iex> {:ok, restored} = ShhAi.PIIPipeline.restore_openai_response(response, mapping: mapping)
      iex> restored
      %{"choices" => [%{"message" => %{"content" => "Hello John"}}]}

  """
  @spec restore_openai_response(response :: term(), opts :: keyword()) ::
          {:ok, restored :: term()}
  def restore_openai_response(response, opts \\ []) do
    mapping = get_mapping(opts)

    if map_size(mapping) == 0 do
      {:ok, response}
    else
      PII.Sanitizer.restore_response(response, mapping)
    end
  end

  @doc """
  Restore PII in a streaming chunk that's in OpenAI format.

  For streaming, we need to handle partial JSON and SSE format.
  This function processes each chunk and restores any PII placeholders.

  ## Options

    * `:mapping` - The mapping to use for restoration

  """
  @spec restore_openai_stream_chunk(chunk :: String.t(), mapping :: mapping()) ::
          String.t()
  def restore_openai_stream_chunk(chunk, mapping) when is_binary(chunk) do
    if map_size(mapping) == 0 do
      chunk
    else
      {:ok, response} = PII.Sanitizer.restore(chunk, mapping)

      response
    end
  end

  # Private helpers

  defp pii_enabled?(opts) do
    case Keyword.get(opts, :enabled) do
      nil -> ShhAi.Config.pii_enabled()
      enabled -> enabled
    end
  end

  defp maybe_store_mapping(nil, _mapping), do: :ok
  defp maybe_store_mapping(session_id, mapping), do: SessionStore.put(session_id, mapping)

  defp get_mapping(opts) do
    case Keyword.get(opts, :mapping) do
      nil ->
        case Keyword.get(opts, :session_id) do
          nil -> %{}
          session_id -> get_session_mapping(session_id)
        end

      mapping ->
        mapping
    end
  end

  defp get_session_mapping(session_id) do
    case SessionStore.get(session_id) do
      {:ok, mapping} -> mapping
      {:error, _} -> %{}
    end
  end
end
