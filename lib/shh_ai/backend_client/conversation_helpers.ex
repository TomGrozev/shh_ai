defmodule ShhAi.BackendClient.ConversationHelpers do
  @moduledoc false

  alias ShhAi.Conversation
  alias ShhAi.ConversationFingerprinter

  @doc """
  Finds or creates a Conversation from the OpenAI-format request body.
  """
  @spec find_or_create(map() | binary(), atom()) :: {:ok, Conversation.t()} | {:error, term()}
  def find_or_create(parsed_body, source_provider) do
    messages = if is_map(parsed_body), do: parsed_body["messages"] || [], else: []

    fingerprint =
      if length(messages) > 1,
        do: ConversationFingerprinter.fingerprint_for_lookup(messages),
        else: nil

    provider_conversation_id =
      case extract_conversation_id(parsed_body) do
        {:stateful, id} -> id
        :stateless -> nil
      end

    Conversation.find_or_create(fingerprint, %{
      provider_conversation_id: provider_conversation_id,
      source_provider: source_provider
    })
  end

  @doc """
  Gets the PII mapping for a conversation, returning an empty map on error.
  """
  @spec get_mapping(Conversation.t()) :: map()
  def get_mapping(%Conversation{} = conversation) do
    case Conversation.get_mapping(conversation.conversation_id) do
      {:ok, mapping} -> mapping
      {:error, _} -> %{}
    end
  end

  @doc """
  Updates the conversation fingerprint after a non-streaming request,
  migrating from temporary UUID v4 to deterministic UUID v5 on Turn 1.
  """
  @spec update_fingerprint(Conversation.t(), map(), map()) :: String.t()
  def update_fingerprint(conversation, openai_body, openai_response) do
    import ShhAi.BackendClient.SSEParser, only: [extract_assistant_message: 1]
    import ShhAi.BackendClient.FingerprintMigration, only: [migrate_or_update: 2]

    messages = if is_map(openai_body), do: openai_body["messages"] || [], else: []

    full_fingerprint =
      ConversationFingerprinter.fingerprint_messages(
        messages ++ [extract_assistant_message(openai_response)]
      )

    if is_nil(full_fingerprint),
      do: conversation.conversation_id,
      else: migrate_or_update(conversation, full_fingerprint)
  end

  # Extracts a stateful conversation ID from the parsed request body.
  defp extract_conversation_id(body) when not is_map(body), do: :stateless
  defp extract_conversation_id(%{"thread_id" => id}) when is_binary(id), do: {:stateful, id}
  defp extract_conversation_id(%{"conversation" => id}) when is_binary(id), do: {:stateful, id}
  defp extract_conversation_id(_), do: :stateless
end
