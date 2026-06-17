defmodule ShhAi.BackendClient.FingerprintFinalizer do
  @moduledoc """
  Handles conversation finalization after a response is received.

  On Turn 1 (new conversation, not yet persisted), computes the first-exchange
  fingerprint (first 2 messages), derives a deterministic UUID v5, and persists
  the conversation to the store with its accumulated mapping.

  On Turn 2+ (existing conversation), updates the stored full fingerprint
  metadata and touches the conversation to reset its sliding TTL.

  This module implements deferred storage: instead of writing to ETS on Turn 1 with
  a temporary ID and then migrating, we defer persistence until the first-exchange
  fingerprint is available, deriving a stable UUID v5 from creation.
  """

  alias ShhAi.Conversation
  alias ShhAi.ConversationFingerprinter
  alias ShhAi.ConversationStore

  @doc """
  Finalizes a Turn 1 conversation by persisting it with the UUID v5 derived
  from the first-exchange fingerprint.

  ## Parameters

    - `conversation` — the in-memory `Conversation.t()` struct from `find_or_create(nil, ...)`
    - `messages` — the full message list including the assistant response (at least 2 messages)
    - `mapping` — the accumulated PII mapping from Turn 1 sanitization
    - `reverse_index` — the reverse index from Turn 1 sanitization

  ## Returns

  The final conversation ID (UUID v5), or the original conversation ID if
  fewer than 2 messages are provided (fingerprint cannot be derived).
  """
  @spec finalize_turn_1(Conversation.t(), [map()], map(), map()) :: String.t()
  def finalize_turn_1(%Conversation{new?: true} = conversation, messages, mapping, reverse_index)
      when is_list(messages) and length(messages) >= 2 do
    # Compute first-exchange fingerprint (first 2 messages)
    lookup_fingerprint = ConversationFingerprinter.fingerprint_for_lookup(messages)
    full_fingerprint = ConversationFingerprinter.fingerprint_messages(messages)

    # Derive UUID v5
    new_id = ConversationFingerprinter.derive_conversation_id(lookup_fingerprint)

    # Persist conversation with final ID
    :ok =
      ConversationStore.create(%Conversation{
        conversation_id: new_id,
        source_provider: conversation.source_provider,
        provider_conversation_id: conversation.provider_conversation_id,
        mapping: %{},
        reverse_index: %{},
        created_at: conversation.created_at,
        last_active_at: System.monotonic_time(:millisecond),
        fingerprint_hash: full_fingerprint,
        new?: false
      })

    # Persist mapping and reverse index
    if map_size(mapping) > 0 do
      ConversationStore.add_mapping(new_id, mapping, reverse_index)
    end

    Conversation.touch(new_id)

    new_id
  end

  # Fallback for fewer than 2 messages — fingerprint cannot be derived from
  # a single message, so persist with the temporary ID as-is.
  def finalize_turn_1(%Conversation{new?: true} = conversation, messages, mapping, reverse_index)
      when is_list(messages) do
    # Persist conversation with the temporary ID
    :ok =
      ConversationStore.create(%Conversation{
        conversation_id: conversation.conversation_id,
        source_provider: conversation.source_provider,
        provider_conversation_id: conversation.provider_conversation_id,
        mapping: %{},
        reverse_index: %{},
        created_at: conversation.created_at,
        last_active_at: System.monotonic_time(:millisecond),
        fingerprint_hash: nil,
        new?: false
      })

    # Persist mapping and reverse index
    if map_size(mapping) > 0 do
      ConversationStore.add_mapping(conversation.conversation_id, mapping, reverse_index)
    end

    Conversation.touch(conversation.conversation_id)

    conversation.conversation_id
  end

  @doc """
  Updates an existing conversation's fingerprint metadata after a response.

  Computes the full fingerprint (all messages) and stores it as metadata.
  Touches the conversation to reset its sliding TTL.

  ## Parameters

    - `conversation` — the existing `Conversation.t()` struct
    - `messages` — the full message list including the assistant response

  ## Returns

  The conversation ID (unchanged).
  """
  @spec update_existing(Conversation.t(), [map()]) :: String.t()
  def update_existing(%Conversation{new?: false} = conversation, messages)
      when is_list(messages) do
    full_fingerprint = ConversationFingerprinter.fingerprint_messages(messages)
    Conversation.update_fingerprint(conversation.conversation_id, full_fingerprint)
    Conversation.touch(conversation.conversation_id)
    conversation.conversation_id
  end
end
