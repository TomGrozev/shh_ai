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
  Always creates a new Conversation. Conversation identification (fingerprint
  lookup) is deferred to issue #6.
  """
  @spec find_or_create(fingerprint_hash(), map()) :: {:ok, t()} | {:error, term()}
  def find_or_create(fingerprint, metadata \\ %{}) do
    conversation_id = get_id(fingerprint)
    now = System.monotonic_time(:millisecond)

    conversation = %Conversation{
      conversation_id: conversation_id,
      source_provider: Map.get(metadata, :source_provider),
      provider_conversation_id: Map.get(metadata, :provider_conversation_id),
      mapping: %{},
      reverse_index: %{},
      created_at: now,
      last_active_at: now,
      fingerprint_hash: nil,
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
  Computes a deterministic SHA-256 hex hash of a canonical-format message.

  The hash covers `role` concatenated with the message text content. Content
  may be either a binary string or a list of content parts (OpenAI format);
  text parts are concatenated in order, non-text parts are ignored.

  Used by message fingerprinting (composite hash of `messages[0..-2]`) and
  by the per-conversation message cache.

  ## Examples

      iex> ShhAi.Conversation.hash_message(%{role: "user", content: "Hello"})
      "..."

      iex> ShhAi.Conversation.hash_message(%{
      ...>   role: "user",
      ...>   content: [%{"type" => "text", "text" => "Hello"}, %{"type" => "text", "text" => " world"}]
      ...> })
      # same hash as %{role: "user", content: "Hello world"}
  """
  @spec hash_message(%{required(:role) => term(), required(:content) => term()}) ::
          String.t()
  def hash_message(%{role: role, content: content}) do
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
    parts
    |> Enum.map(&extract_text_part/1)
    |> IO.iodata_to_binary()
  end

  defp extract_text(other), do: to_string(other)

  # OpenAI content-part shape: %{"type" => "text", "text" => "..."}.
  # Atom-keyed shape is also accepted for callers that build messages with
  # atom keys rather than string keys.
  defp extract_text_part(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp extract_text_part(%{type: :text, text: text}) when is_binary(text), do: text
  defp extract_text_part(_other), do: ""

  defp get_id(nil), do: UUID.uuid4()

  defp get_id(_fingerprint) do
    # TODO: generate fingerprint uuidv5
    UUID.uuid4()
  end
end
