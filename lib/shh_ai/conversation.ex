defmodule ShhAi.Conversation do
  @moduledoc """
  Conversation-scoped PII tracking for the privacy proxy.

  A `Conversation` groups related proxy requests that share an accumulated PII
  mapping and a message cache. Conversations are identified either by a
  stateful-API signal (e.g. `thread_id`, `conversation`) or, for stateless
  APIs, by a fingerprint of the message history.
  """
  require Logger
  alias ShhAi.Conversation

  @typedoc "Unique Conversation identifier (UUID v4 binary)."
  @type conversation_id :: String.t()

  @typedoc "Source provider atom — `:openai` | `:anthropic` | `:ollama`."
  @type source_provider :: :openai | :anthropic | :ollama

  @typedoc "Provider-supplied stateful conversation ID (thread_id, etc.)."
  @type provider_conversation_id :: String.t() | nil

  @typedoc "Accumulated PII placeholder → original value mapping."
  @type mapping :: %{{atom(), number()} => String.t()}

  @typedoc "Reverse index: `{original_value, pii_type}` → placeholder key."
  @type reverse_index :: %{{String.t(), atom()} => {atom(), pos_integer()}}

  @typedoc "Monotonic time in milliseconds (matches `System.monotonic_time(:millisecond)`)."
  @type monotonic_ms :: integer()

  @typedoc "SHA-256 hash of the conversation fingerprint (nil for now, wired up in issue #6)."
  @type fingerprint_hash :: String.t() | nil

  @type t :: %__MODULE__{
          conversation_id: conversation_id(),
          source_provider: source_provider(),
          provider_conversation_id: provider_conversation_id(),
          mapping: mapping(),
          reverse_index: reverse_index(),
          created_at: monotonic_ms(),
          last_active_at: monotonic_ms(),
          fingerprint_hash: fingerprint_hash(),
          new?: boolean()
        }

  defstruct [
    :conversation_id,
    :source_provider,
    :provider_conversation_id,
    :mapping,
    :reverse_index,
    :created_at,
    :last_active_at,
    :fingerprint_hash,
    :new?
  ]

  @doc """
  Finds an existing Conversation by fingerprint, or creates a new one.

  ## Parameters

    - `:fingerprint` — a 64-char hex fingerprint hash (Turn 2+), or `nil` (Turn 1)
    - `attrs` — a map with the following keys:
      - `:source_provider` — the source provider atom
      - `:provider_conversation_id` — the provider-supplied conversation ID, or `nil`

  ## Behaviour

  **Turn 1 (nil fingerprint):** generates a UUID v4, creates a new Conversation
  in the store, and returns `{:ok, %Conversation{new?: true, ...}}`.

  **Turn 2+ (fingerprint is a string):** derives a UUID v5 from the fingerprint,
  looks up the existing Conversation in the store. If found, returns
  `{:ok, %Conversation{new?: false, ...}}`. If not found, creates a new
  Conversation with the UUID v5 and returns `{:ok, %Conversation{new?: true, ...}}`.
  """
  @spec find_or_create(String.t() | nil, map()) :: {:ok, t()} | {:error, term()}
  # Turn 1: no fingerprint yet — generate a fresh UUID v4.
  def find_or_create(nil, attrs) when is_map(attrs) do
    create_new_conversation(
      UUID.uuid4(),
      nil,
      attrs
    )
  end

  # Turn 2+: derive a deterministic UUID v5 from the fingerprint.
  def find_or_create(fingerprint, attrs) when is_map(attrs) and is_binary(fingerprint) do
    conversation_id = ShhAi.ConversationFingerprinter.derive_conversation_id(fingerprint)

    case ShhAi.ConversationStore.get_conversation(conversation_id) do
      {:ok, conversation} ->
        # Found an existing conversation — return it with new?: false.
        {:ok, %{conversation | new?: false}}

      {:error, :not_found} ->
        # No existing conversation for this fingerprint — create one.
        create_new_conversation(
          conversation_id,
          fingerprint,
          attrs
        )
    end
  end

  @doc """
  Adds mapping entries and reverse index entries to a Conversation's
  accumulated PII state.

  Delegates to `ShhAi.ConversationStore.ETS.add_mapping/3`, which uses
  `:ets.insert_new/2` for atomic placeholder assignment: an existing
  `placeholder_key` is never overwritten — first writer wins.
  """
  @spec add_mapping(conversation_id(), mapping(), reverse_index()) :: :ok
  def add_mapping(conversation_id, new_mapping, new_reverse_index) do
    ShhAi.ConversationStore.add_mapping(conversation_id, new_mapping, new_reverse_index)
  end

  @doc """
  Returns the accumulated PII mapping for a Conversation, or
  `{:error, :not_found}` if no Conversation with that ID exists.

  Delegates to `ShhAi.ConversationStore.get_mapping/1`.
  """
  @spec get_mapping(conversation_id()) :: {:ok, mapping()} | {:error, :not_found}
  def get_mapping(conversation_id) do
    ShhAi.ConversationStore.get_mapping(conversation_id)
  end

  @doc """
  Looks up the placeholder key assigned to a previously-seen
  `{original_value, pii_type}` pair in a Conversation's reverse index.

  Returns `{:ok, placeholder_key}` if the PII value has been seen before in
  this Conversation, or `{:error, :not_found}` if it has not (or if the
  Conversation does not exist).

  This is the O(1) reuse check at the heart of placeholder consistency:
  when the sanitizer detects a PII value, it asks the Conversation
  whether it already has a placeholder for that `{value, type}` pair, and
  reuses it instead of minting a new one.

  Delegates to `ShhAi.ConversationStore.lookup_placeholder/3`.
  """
  @spec lookup_placeholder(conversation_id(), String.t(), atom()) ::
          {:ok, String.t()} | {:error, :not_found}
  def lookup_placeholder(conversation_id, original_value, pii_type) do
    ShhAi.ConversationStore.lookup_placeholder(
      conversation_id,
      original_value,
      pii_type
    )
  end

  @doc """
  Resets the Conversation's sliding TTL clock by bumping `last_active_at`
  to the current monotonic time.

  Returns `:ok` on success, or `{:error, :not_found}` if no Conversation
  with that ID exists. The caller (typically the proxy request pipeline)
  invokes this on each new request within a Conversation — the sliding
  TTL design (see ADR 0007) means an active Conversation is never evicted
  as long as traffic continues, but it expires `conversation_ttl`
  (default 1 hour) after the last request.

  Delegates to `ShhAi.ConversationStore.touch/1`.
  """
  @spec touch(conversation_id()) :: :ok | {:error, :not_found}
  def touch(conversation_id) do
    ShhAi.ConversationStore.touch(conversation_id)
  end

  @doc """
  Deletes a Conversation and all of its accumulated state (the row in
  `:conversations`, every mapping in `:conversation_mappings`, and every
  reverse-index entry in `:conversation_reverse_index`).

  Idempotent — deleting a non-existent Conversation returns `:ok`.
  This makes the function safe to call from cleanup passes and from any
  retry logic that doesn't track prior state.

  Delegates to `ShhAi.ConversationStore.delete/1`.
  """
  @spec delete(conversation_id()) :: :ok
  def delete(conversation_id) do
    ShhAi.ConversationStore.delete(conversation_id)
  end

  @doc """
  Moves all conversation data from `old_id` to `new_id`.

  Used for migrating a temporary UUID v4 to a deterministic UUID v5 once the
  fingerprint becomes available.

  Delegates to `ShhAi.ConversationStore.migrate_id/2`.
  """
  @spec migrate_id(String.t(), String.t()) :: :ok | {:error, term()}
  def migrate_id(old_id, new_id) do
    ShhAi.ConversationStore.migrate_id(old_id, new_id)
  end

  @doc """
  Updates the fingerprint hash for an existing Conversation.

  Called after Turn 2+ when the full message history changes and the
  fingerprint needs to be refreshed.

  Delegates to `ShhAi.ConversationStore.update_fingerprint/2`.
  """
  @spec update_fingerprint(String.t(), String.t()) :: :ok | {:error, term()}
  def update_fingerprint(conversation_id, fingerprint_hash) do
    ShhAi.ConversationStore.update_fingerprint(conversation_id, fingerprint_hash)
  end

  @doc """
  Caches the sanitized version of a message for a Conversation.

  The `message_hash` is a SHA-256 hex hash (from `hash_message/1`) and
  `sanitized_content` is the sanitized form of the message (typically a
  tuple of `{sanitized_text, new_mapping, new_reverse_index, counts}`).

  On a cache hit (same message in a subsequent turn), the cached content
  is reused, skipping redundant NER and regex processing.

  Delegates to `ShhAi.ConversationStore.cache_message/3`.
  """
  @spec cache_message(conversation_id(), String.t(), term()) :: :ok
  def cache_message(conversation_id, message_hash, sanitized_content) do
    ShhAi.ConversationStore.cache_message(conversation_id, message_hash, sanitized_content)
  end

  @doc """
  Looks up a previously cached sanitized message for a Conversation.

  Returns `{:ok, sanitized_content}` if the message was cached (cache hit),
  or `{:error, :not_found}` if the message has not been cached (cache miss)
  or the Conversation does not exist.

  Delegates to `ShhAi.ConversationStore.lookup_message/2`.
  """
  @spec lookup_message(conversation_id(), String.t()) :: {:ok, term()} | {:error, :not_found}
  def lookup_message(conversation_id, message_hash) do
    ShhAi.ConversationStore.lookup_message(conversation_id, message_hash)
  end

  @doc """
  Caches an assistant response for future message cache hits.

  The `hash` covers the RESTORED content (what the client sees), and the
  cached value is the PRE-RESTORED content (with PII placeholders). This
  allows the next turn's sanitization to reuse the cached placeholder form
  without re-running NER.

  No-op when the mapping is empty or the content is blank.
  """
  @spec cache_assistant_response(conversation_id(), String.t(), map()) :: :ok
  def cache_assistant_response(conversation_id, pre_restored_content, mapping) do
    if map_size(mapping) > 0 and pre_restored_content != "" do
      {:ok, restored_content} = ShhAi.PII.Sanitizer.restore(pre_restored_content, mapping)

      hash = hash_message(%{role: "assistant", content: restored_content})

      cache_message(
        conversation_id,
        hash,
        {:assistant_message, pre_restored_content}
      )
    else
      :ok
    end
  end

  @doc """
  Computes a deterministic SHA-256 hex hash of a canonical-format message.

  The hash covers `role` concatenated with the message text content. Content
  may be either a binary string or a list of content parts (OpenAI format);
  text parts are concatenated in order, non-text parts are ignored. For list
  content, the part count is included to differentiate messages with different
  non-text parts (images, tool calls, etc.) that would otherwise hash identically.

  Used by message fingerprinting (composite hash of `messages[0..-2]`) and
  by the per-conversation message cache.

  ## Examples

      iex> ShhAi.Conversation.hash_message(%{role: "user", content: "Hello"})
      "..."

      iex> ShhAi.Conversation.hash_message(%{
      ...>   role: "user",
      ...>   content: [%{"type" => "text", "text" => "Hello"}, %{"type" => "text", "text" => " world"}]
      ...> })
      # different from string hash due to part count inclusion
  """
  @spec hash_message(%{required(:role) => term(), required(:content) => term()}) ::
          String.t()
  def hash_message(%{role: role, content: content}) do
    payload = to_string(role) <> extract_text(content)
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # Handle string-keyed maps (from OpenAI JSON format)
  def hash_message(%{"role" => role, "content" => content}) do
    payload = to_string(role) <> extract_text(content)
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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

  defp create_new_conversation(
         conversation_id,
         fingerprint_hash,
         attrs
       ) do
    source_provider = Map.get(attrs, :source_provider)
    provider_conversation_id = Map.get(attrs, :provider_conversation_id)
    now = System.monotonic_time(:millisecond)

    conversation = %Conversation{
      conversation_id: conversation_id,
      source_provider: source_provider,
      provider_conversation_id: provider_conversation_id,
      mapping: %{},
      reverse_index: %{},
      created_at: now,
      last_active_at: now,
      fingerprint_hash: fingerprint_hash,
      new?: true
    }

    case ShhAi.ConversationStore.create(conversation) do
      {:error, reason} ->
        Logger.error("Failed to create conversation, reason: #{inspect(reason)}")
        {:error, reason}

      :ok ->
        {:ok, conversation}
    end
  end
end
