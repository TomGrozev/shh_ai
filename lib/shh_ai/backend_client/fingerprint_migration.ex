defmodule ShhAi.BackendClient.FingerprintMigration do
  @moduledoc false

  require Logger

  alias ShhAi.Conversation
  alias ShhAi.ConversationFingerprinter

  @doc """
  Updates the conversation fingerprint, migrating from a temporary UUID v4
  to a deterministic UUID v5 on the first turn.

  Returns the final conversation ID (possibly migrated).
  """
  @spec migrate_or_update(Conversation.t(), String.t() | nil) :: String.t()
  def migrate_or_update(_conversation, nil) do
    nil
  end

  def migrate_or_update(conversation, full_fingerprint) do
    if conversation.new? do
      migrate_new(conversation, full_fingerprint)
    else
      update_existing(conversation, full_fingerprint)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Turn 1: migrate from temporary UUID v4 to deterministic UUID v5.
  defp migrate_new(conversation, full_fingerprint) do
    new_id = ConversationFingerprinter.derive_conversation_id(full_fingerprint)

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
  # INVARIANT: after update, derive_conversation_id(stored_fingerprint) == ETS row key.
  # When the fingerprint changes (more messages added), the derived UUID v5 may
  # differ from the current row key. In that case we must migrate the ETS key
  # to maintain the invariant; otherwise a subsequent find_or_create (which
  # derives the ID from the fingerprint) would fail to find the row.
  defp update_existing(conversation, full_fingerprint) do
    new_id = ConversationFingerprinter.derive_conversation_id(full_fingerprint)

    if new_id != conversation.conversation_id do
      # Fingerprint changed -> migrate the ETS key so that
      # derive_conversation_id(stored_fingerprint) == ETS key remains true.
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
      # Fingerprint-derived ID is unchanged -> just update the stored hash in place.
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
