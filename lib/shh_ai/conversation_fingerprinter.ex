defmodule ShhAi.ConversationFingerprinter do
  @moduledoc """
  Produces a deterministic composite SHA-256 fingerprint for a list of
  conversation messages.

  Each message is individually hashed via `ShhAi.Conversation.hash_message/1`,
  then the per-message digests are concatenated with a newline delimiter and
  hashed once more to produce a single 64-character lowercase hex fingerprint.
  """

  alias ShhAi.Conversation

  # Per-deployment namespace UUID for deriving conversation IDs via UUID v5.
  # Configured per environment - production derives it from SECRET_KEY_BASE,
  # while dev/test use the well-known DNS namespace UUID (RFC 4122, Appendix C)
  # for deterministic behavior.
  # NOTE: If the SECRET_KEY_BASE is changed in production, then all previous
  # conversations will be invalidated.
  @namespace_uuid Application.compile_env(
                    :shh_ai,
                    [ShhAi.ConversationFingerprinter, :namespace_uuid],
                    "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
                  )

  @doc """
  Derives a deterministic conversation UUID v5 from a fingerprint hash.

  Takes a 64-character hex fingerprint string and returns a 36-character UUID v5.
  Returns `nil` when the fingerprint is `nil`.

  Uses a fixed namespace UUID so the same fingerprint always maps to the same
  conversation ID.

  ## Examples

      iex> derive_conversation_id(nil)
      nil

      iex> id = derive_conversation_id("ac0d95c35a3b6aa59bd3ecc83f1139731a0da4937273005fe33600c390076d00")
      iex> is_binary(id) and byte_size(id) == 36
      true
  """
  @spec derive_conversation_id(String.t() | nil) :: String.t() | nil
  def derive_conversation_id(nil), do: nil

  def derive_conversation_id(fingerprint) when is_binary(fingerprint) do
    UUID.uuid5(@namespace_uuid, fingerprint)
  end

  @doc """
  Returns a composite SHA-256 hex fingerprint for the given message list.

  - `[]` → `nil` (no messages)
  - `[_single]` → `nil` (first turn has no prior context to fingerprint)
  - 2+ messages → 64-char lowercase hex string

  ## Examples

      iex> fingerprint_messages([])
      nil

      iex> fingerprint_messages([%{role: "user", content: "Hello"}])
      nil

      iex> msgs = [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi"}]
      iex> hash = fingerprint_messages(msgs)
      iex> is_binary(hash) and byte_size(hash) == 64
      true
  """
  @spec fingerprint_messages([map()]) :: String.t() | nil
  def fingerprint_messages([]), do: nil
  def fingerprint_messages([_single]), do: nil

  def fingerprint_messages(messages) when is_list(messages) do
    composite =
      messages
      |> Enum.map_join("\n", &Conversation.hash_message/1)

    :crypto.hash(:sha256, composite) |> Base.encode16(case: :lower)
  end

  @doc """
  Hashes only the first two messages (the opening user message and assistant
  response). This produces a stable fingerprint for conversation lookup that
  does not change as the conversation grows.

  Returns `nil` when the list has fewer than 2 messages.
  """
  @spec fingerprint_for_lookup([map()]) :: String.t() | nil
  def fingerprint_for_lookup([]), do: nil
  def fingerprint_for_lookup([_single]), do: nil

  def fingerprint_for_lookup(messages) when is_list(messages) do
    messages
    |> Enum.take(2)
    |> fingerprint_messages()
  end
end
