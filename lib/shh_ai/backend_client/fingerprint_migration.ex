defmodule ShhAi.BackendClient.FingerprintMigration do
  @moduledoc """
  Manages conversation fingerprint migration and updates.

  On Turn 1, migrates from temporary UUID v4 to deterministic UUID v5 derived
  from the first-exchange fingerprint (2 messages). On Turn 2+, the lookup
  fingerprint is stable (always the first 2 messages), so
  `derive_conversation_id(lookup_fingerprint)` matches the existing ETS row key
  — no key migration needed, just an in-place fingerprint hash update.

  The **full fingerprint** (all messages) is stored as metadata for debugging;
  the **lookup fingerprint** (first 2 messages) drives the conversation ID.
  """

  require Logger

  alias ShhAi.Conversation
  alias ShhAi.ConversationFingerprinter

  @doc """
  Updates the conversation fingerprint, migrating from a temporary UUID v4
  to a deterministic UUID v5 on the first turn.

  - `full_fingerprint` — hash of ALL messages (stored as metadata)
  - `lookup_fingerprint` — hash of first 2 messages (drives ID derivation)

  Returns the final conversation ID (possibly migrated).
  """
  @spec migrate_or_update(Conversation.t(), String.t() | nil, String.t() | nil) :: String.t()
  def migrate_or_update(_conversation, nil, _lookup_fingerprint), do: nil
  def migrate_or_update(_conversation, _full_fingerprint, nil), do: nil

  def migrate_or_update(conversation, full_fingerprint, lookup_fingerprint) do
    if conversation.new? do
      migrate_new(conversation, full_fingerprint, lookup_fingerprint)
    else
      update_existing(conversation, full_fingerprint, lookup_fingerprint)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Turn 1: migrate from temporary UUID v4 to deterministic UUID v5.
  defp migrate_new(conversation, full_fingerprint, lookup_fingerprint) do
    new_id = ConversationFingerprinter.derive_conversation_id(lookup_fingerprint)

    case Conversation.migrate_id(conversation.conversation_id, new_id) do
      :ok ->
        Conversation.update_fingerprint(new_id, full_fingerprint)
        Conversation.touch(new_id)
        new_id

      {:error, reason} ->
        Logger.warning("Failed to migrate conversation: #{inspect(reason)}")
        Conversation.touch(conversation.conversation_id)
        conversation.conversation_id
    end
  end

  # Turn 2+: update stored fingerprint.
  #
  # INVARIANT: after update, derive_conversation_id(lookup_fingerprint) == ETS row key.
  # Since lookup_fingerprint is derived from the first exchange only, the
  # conversation ID is stable after Turn 1 migration. The full fingerprint
  # (all messages) is stored as metadata for debugging but does not drive ID.
  defp update_existing(conversation, full_fingerprint, lookup_fingerprint) do
    new_id = ConversationFingerprinter.derive_conversation_id(lookup_fingerprint)

    if new_id != conversation.conversation_id do
      # Lookup-fingerprint-derived ID differs from current key — migrate the ETS key.
      case Conversation.migrate_id(conversation.conversation_id, new_id) do
        :ok ->
          Conversation.update_fingerprint(new_id, full_fingerprint)
          Conversation.touch(new_id)
          new_id

        {:error, reason} ->
          Logger.warning("Failed to migrate conversation fingerprint: #{inspect(reason)}")
          Conversation.touch(conversation.conversation_id)
          conversation.conversation_id
      end
    else
      # ID unchanged -> just update the stored full fingerprint in place.
      case Conversation.update_fingerprint(conversation.conversation_id, full_fingerprint) do
        :ok ->
          Conversation.touch(conversation.conversation_id)
          conversation.conversation_id

        {:error, reason} ->
          Logger.warning("Failed to update fingerprint: #{inspect(reason)}")
          Conversation.touch(conversation.conversation_id)
          conversation.conversation_id
      end
    end
  end
end
