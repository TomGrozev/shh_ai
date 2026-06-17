defmodule ShhAi.Conversation.Fingerprinter do
  @moduledoc """
  Produces a deterministic composite SHA-256 fingerprint for a list of
  conversation messages.

  Each message is individually hashed via `ShhAi.Conversation.hash_message/1`,
  then the per-message digests are concatenated with a newline delimiter and
  hashed once more to produce a single 64-character lowercase hex fingerprint.
  """

  # Per-deployment namespace UUID for deriving conversation IDs via UUID v5.
  # Configured per environment - production derives it from SECRET_KEY_BASE,
  # while dev/test use the well-known DNS namespace UUID (RFC 4122, Appendix C)
  # for deterministic behavior.
  # NOTE: If the SECRET_KEY_BASE is changed in production, then all previous
  # conversations will be invalidated.
  @namespace_uuid Application.compile_env(
                    :shh_ai,
                    [ShhAi.Conversation.Fingerprinter, :namespace_uuid],
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

  def fingerprint_messages([first, second | _]) do
    composite = Enum.map_join([first, second], "\n", &hash_message/1)

    :crypto.hash(:sha256, composite) |> Base.encode16(case: :lower)
  end

  @doc """
  Hashes a single message
  """
  @spec hash_message(map()) :: String.t()
  def hash_message(%{} = msg) do
    role = Map.get(msg, :role) || Map.get(msg, "role")
    content = Map.get(msg, :content) || Map.get(msg, "content")
    payload = to_string(role) <> extract_text(content)
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # Private helpers

  # Extracts a concatenated text string from message content. Accepts either a
  # binary or a list of content parts (OpenAI format). Non-text parts are
  # skipped; unknown shapes are stringified as a safety net.
  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(parts) when is_list(parts) do
    text =
      parts
      |> Enum.map(&extract_text_part/1)
      |> IO.iodata_to_binary()

    # Include part count to differentiate messages with different non-text parts
    # (images, tool calls, etc.) that would otherwise hash identically
    part_count = length(parts)
    "#{text}\0parts:#{part_count}"
  end

  defp extract_text(other), do: to_string(other)

  # OpenAI content-part shape: %{"type" => "text", "text" => "..."}.
  # Atom-keyed shape is also accepted for callers that build messages with
  # atom keys rather than string keys.
  defp extract_text_part(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp extract_text_part(%{type: :text, text: text}) when is_binary(text), do: text
  defp extract_text_part(_other), do: ""
end
