defmodule ShhAi.Conversation do
  @moduledoc """
  Conversation-scoped PII tracking for the privacy proxy.

  A `Conversation` groups related proxy requests that share an accumulated PII
  Mapping and a message cache. Conversations are identified either by a
  stateful-API signal (e.g. `thread_id`, `conversation`) or, for stateless
  APIs, by a fingerprint of the message history.

  ## Facade seam

  This module is the facade over `ShhAi.Conversation.Store` for
  conversation-scoped state. Consumers — primarily the PII Pipeline — cross
  this single seam for all Conversation-related reads and writes; they
  should not call `Store` directly.

  The public interface is organised into groups:

    * **Mapping reads** — `get_mapping/1` returns the accumulated placeholder
      → original Mapping for a Conversation.
    * **Reverse Index reads** — `get_reverse_index/1` returns the `{value,
      type} → placeholder` lookup enabling O(1) placeholder reuse within a
      Conversation. Symmetric with `get_mapping/1`.
    * **Cache primitives** — `lookup_message/2`, `cache_message/3`
      operate on the per-Conversation Message
      Cache, avoiding re-sanitisation across turns.
    * **Lifecycle** — `find_or_create/2`, `persist_turn/1`,
      `touch/1`, `delete/1` manage Conversation
      identity, persistence, and the sliding TTL.
  """
  require Logger

  alias ShhAi.Audit.Writer, as: AuditWriter
  alias ShhAi.Config
  alias ShhAi.Conversation
  alias ShhAi.Conversation.{Fingerprinter, Store}

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

  @typedoc """
  Audit Mode opt-out flag. `true` means this Conversation was created
  from a request that carried the `X-No-Audit` header — the Audit
  Writer will skip retention for this Conversation even when Audit
  Mode is ON. Mirrors the 7th element of the ETS tuple and the
  `opted_out` column of the `conversations` audit table.
  """
  @type opted_out :: boolean()

  @type t :: %__MODULE__{
          conversation_id: conversation_id(),
          source_provider: source_provider(),
          provider_conversation_id: provider_conversation_id(),
          mapping: mapping(),
          reverse_index: reverse_index(),
          created_at: monotonic_ms(),
          last_active_at: monotonic_ms(),
          fingerprint_hash: fingerprint_hash(),
          opted_out: opted_out(),
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
    :opted_out,
    :new?
  ]

  defdelegate list_conversations(opts), to: Store
  defdelegate hash_message(msg), to: Fingerprinter

  @doc """
  Finds an existing Conversation, or creates a new one.

  Accepts either a message list (computes fingerprint internally) or a
  pre-computed fingerprint/nil.

  ## Message list form

    - `messages` — the list of messages (OpenAI format)
    - `attrs` — a map with `:source_provider` and `:provider_conversation_id`

  ## Fingerprint form

    - `:fingerprint` — a 64-char hex fingerprint hash (Turn 2+), or `nil` (Turn 1)
    - `attrs` — a map with the following keys:
      - `:source_provider` — the source provider atom
      - `:provider_conversation_id` — the provider-supplied conversation ID, or `nil`

  ## Behaviour

  **Turn 1 (nil fingerprint):** creates a new Conversation
  in the store, and returns `{:ok, %Conversation{new?: true, ...}}`.

  **Turn 2+ (fingerprint is a string):** derives a UUID v5 from the fingerprint,
  looks up the existing Conversation in the store. If found, returns
  `{:ok, %Conversation{new?: false, ...}}`. If not found, creates a new
  Conversation with the UUID v5 and returns `{:ok, %Conversation{new?: true, ...}}`.
  """
  @spec find_or_create([map()], map()) :: {:ok, t()} | {:error, term()}
  def find_or_create(messages, attrs) when is_list(messages) and is_map(attrs) do
    fingerprint = Fingerprinter.fingerprint_messages(messages)

    with {:ok, conversation} <- do_find_or_create(fingerprint, attrs) do
      {:ok, conversation}
    end
  end

  @doc """
  Persists all durable writes for a turn. This is the **only** entry point
  that performs Cold Store writes.

  Takes a keyword list with:
    - `:conversation` — the `%Conversation{}` struct (provides `conversation_id` and `new?`)
    - `:sanitized_messages` — list of %{role, content} maps (already sanitized)
    - `:assistant_message_hash` — hash of restored assistant content
    - `:mapping` — full mapping this turn (deltas computed internally)
    - `:reverse_index` — full reverse index this turn (deltas computed internally)
    - `:request_time` — NaiveDateTime for audit rows
    - `:fingerprint` — fingerprint for cold-store writes
  """
  @spec persist_turn(keyword()) :: {:ok, conversation_id()}
  def persist_turn(opts) do
    conversation = Keyword.fetch!(opts, :conversation)
    conversation_id = conversation.conversation_id
    is_new = conversation.new?
    sanitized_messages = Keyword.fetch!(opts, :sanitized_messages)
    assistant_message_hash = Keyword.fetch!(opts, :assistant_message_hash)
    mapping = Keyword.fetch!(opts, :mapping)
    reverse_index = Keyword.fetch!(opts, :reverse_index)
    request_time = Keyword.fetch!(opts, :request_time)
    fingerprint = Keyword.fetch!(opts, :fingerprint)

    # Compute deltas: new entries only (full mapping/reverse_index minus what was already stored)
    existing_mapping = conversation.mapping || %{}
    existing_reverse_index = conversation.reverse_index || %{}
    mapping_delta = Map.drop(mapping, Map.keys(existing_mapping))
    reverse_index_delta = Map.drop(reverse_index, Map.keys(existing_reverse_index))

    # 1. Hot-store conversation row
    if is_new do
      Store.create(%Conversation{
        conversation_id: conversation_id,
        source_provider: conversation.source_provider,
        provider_conversation_id: conversation.provider_conversation_id,
        mapping: %{},
        reverse_index: %{},
        created_at: conversation.created_at,
        last_active_at: System.monotonic_time(:millisecond),
        fingerprint_hash: fingerprint,
        opted_out: conversation.opted_out || false,
        new?: false
      })
    else
      Store.touch(conversation_id)
    end

    # 2. Hot-store mapping accumulation
    if map_size(mapping_delta) > 0 do
      Store.add_mapping(conversation_id, mapping_delta, reverse_index_delta)
    end

    # 3. Hot-store message cache
    Enum.each(sanitized_messages, fn msg ->
      hash = Fingerprinter.hash_message(msg)
      Store.cache_message(conversation_id, hash, {:cached, msg["role"], msg["content"]})
    end)

    # Also cache the assistant message by its restored-content hash
    if assistant_message_hash != "" do
      assistant_msg = Enum.find(sanitized_messages, fn m -> m["role"] == "assistant" end)

      if assistant_msg do
        Store.cache_message(
          conversation_id,
          assistant_message_hash,
          {:assistant_message, assistant_msg["content"]}
        )
      end
    end

    # 4–6. Cold-store writes (gated by Config.audit_mode?())
    persist_cold_store(conversation, sanitized_messages, mapping_delta, request_time, fingerprint)

    {:ok, conversation_id}
  end

  @doc """
  Adds mapping entries and reverse index entries to a Conversation's
  accumulated PII state.

  Pure ETS write — no audit cast. The durable write is handled by
  `persist_turn/1`.
  """
  @spec add_mapping(conversation_id(), mapping(), reverse_index()) :: :ok
  def add_mapping(conversation_id, new_mapping, new_reverse_index) do
    Store.add_mapping(conversation_id, new_mapping, new_reverse_index)
    :ok
  end

  @doc """
  Returns the accumulated PII mapping for a Conversation, or
  `{:error, :not_found}` if no Conversation with that ID exists.

  Delegates to `Store.get_mapping/1`.
  """
  @spec get_mapping(conversation_id()) :: {:ok, mapping()} | {:error, :not_found}
  def get_mapping(conversation_id) do
    Store.get_mapping(conversation_id)
  end

  @doc """
  Returns the reverse index for a Conversation — the lookup table from
  `{original_value, pii_type}` to placeholder key enabling O(1) placeholder
  reuse within a Conversation.

  Returns `{:ok, reverse_index}` on success, or `{:error, :not_found}` if
  no Conversation with that ID exists.

  Delegates to `Store.get_reverse_index/1`.
  """
  @spec get_reverse_index(conversation_id()) ::
          {:ok, reverse_index()} | {:error, :not_found}
  def get_reverse_index(conversation_id) do
    Store.get_reverse_index(conversation_id)
  end

  @doc """
  Looks up the placeholder key assigned to a previously-seen
  `{original_value, pii_type}` pair in a Conversation's reverse index.

  Returns `{:ok, placeholder_key}` if the PII value has been seen before in
  this Conversation, or `{:error, :not_found}` if it has not (or if the
  Conversation does not exist).

  Delegates to `Store.lookup_placeholder/3`.
  """
  @spec lookup_placeholder(conversation_id(), String.t(), atom()) ::
          {:ok, String.t()} | {:error, :not_found}
  def lookup_placeholder(conversation_id, original_value, pii_type) do
    Store.lookup_placeholder(
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

  Delegates to `Store.touch/1`.
  """
  @spec touch(conversation_id()) :: :ok | {:error, :not_found}
  def touch(conversation_id) do
    Store.touch(conversation_id)
  end

  @doc """
  Deletes a Conversation and all of its accumulated state (the row in
  `:conversations`, every mapping in `:conversation_mappings`, and every
  reverse-index entry in `:conversation_reverse_index`).

  Idempotent — deleting a non-existent Conversation returns `:ok`.
  This makes the function safe to call from cleanup passes and from any
  retry logic that doesn't track prior state.

  Delegates to `Store.delete/1`.
  """
  @spec delete(conversation_id()) :: :ok
  def delete(conversation_id) do
    Store.delete(conversation_id)
  end

  @doc """
  Updates the fingerprint hash for an existing Conversation.

  Called after Turn 2+ when the full message history changes and the
  fingerprint needs to be refreshed.

  Delegates to `Store.update_fingerprint/2`.
  """
  @spec update_fingerprint(String.t(), String.t()) :: :ok | {:error, term()}
  def update_fingerprint(conversation_id, fingerprint_hash) do
    Store.update_fingerprint(conversation_id, fingerprint_hash)
  end

  @doc """
  Caches the sanitized version of a message for a Conversation.

  Pure ETS write — no audit cast. The durable write is handled by
  `persist_turn/1`.

  Delegates to `Store.cache_message/3`.
  """
  @spec cache_message(conversation_id(), String.t(), term()) :: :ok
  def cache_message(conversation_id, message_hash, sanitized_content) do
    Store.cache_message(conversation_id, message_hash, sanitized_content)
    :ok
  end

  @doc """
  Looks up a previously cached sanitized message for a Conversation.

  Returns `{:ok, sanitized_content}` if the message was cached (cache hit),
  or `{:error, :not_found}` if the message has not been cached (cache miss)
  or the Conversation does not exist.

  Delegates to `Store.lookup_message/2`.
  """
  @spec lookup_message(conversation_id(), String.t()) :: {:ok, term()} | {:error, :not_found}
  def lookup_message(conversation_id, message_hash) do
    Store.lookup_message(conversation_id, message_hash)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Turn 1: no fingerprint yet
  # Deferred storage: build in-memory struct without persisting to ETS.
  # The conversation will be persisted later when the Turn 1 response
  # arrives and the fingerprint is finalized (see persist_turn/1).
  defp do_find_or_create(nil, attrs) when is_map(attrs) do
    source_provider = Map.get(attrs, :source_provider)
    provider_conversation_id = Map.get(attrs, :provider_conversation_id)
    opted_out = Map.get(attrs, :opted_out, false)
    now = System.monotonic_time(:millisecond)

    conversation = %Conversation{
      conversation_id: UUID.uuid4(),
      source_provider: source_provider,
      provider_conversation_id: provider_conversation_id,
      mapping: %{},
      reverse_index: %{},
      created_at: now,
      last_active_at: now,
      fingerprint_hash: nil,
      opted_out: opted_out,
      new?: true
    }

    {:ok, conversation}
  end

  # Turn 2+: derive a deterministic UUID v5 from the fingerprint.
  defp do_find_or_create(fingerprint, attrs) when is_map(attrs) and is_binary(fingerprint) do
    conversation_id = Fingerprinter.derive_conversation_id(fingerprint)

    case Store.get_conversation(conversation_id) do
      {:ok, conversation} ->
        # Found an existing conversation — return it with new?: false.
        # If the request carries opted_out, set it on the existing
        # conversation (sticky: only false → true).
        new_conversation = %{conversation | new?: false}

        if Map.get(attrs, :opted_out, false) and not conversation.opted_out do
          :ok = Store.set_opted_out(conversation_id)
          {:ok, %{new_conversation | opted_out: true}}
        else
          {:ok, new_conversation}
        end

      {:error, :not_found} ->
        # No existing conversation for this fingerprint — create one.
        create_new_conversation(
          conversation_id,
          fingerprint,
          attrs
        )
    end
  end

  defp create_new_conversation(
         conversation_id,
         fingerprint_hash,
         attrs
       ) do
    source_provider = Map.get(attrs, :source_provider)
    provider_conversation_id = Map.get(attrs, :provider_conversation_id)
    opted_out = Map.get(attrs, :opted_out, false)
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
      opted_out: opted_out,
      new?: true
    }

    case Store.create(conversation) do
      :ok ->
        {:ok, conversation}

      {:error, reason} ->
        Logger.error("Failed to create conversation, reason: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Cold Store writes (Audit Mode)
  # ---------------------------------------------------------------------------

  # Writes conversation row, message rows, and mapping to the Cold Store.
  # All paths gated by Config.audit_mode?().
  defp persist_cold_store(conversation, sanitized_messages, mapping_delta, request_time, fingerprint) do
    if Config.audit_mode?() do
      # 4. Cold-store conversation row (Turn 1 only)
      if conversation.new? do
        do_write_conversation(conversation.conversation_id, conversation, mapping_delta, request_time, fingerprint)
      end

      # 5. Cold-store message rows (all turns)
      Enum.each(sanitized_messages, fn msg ->
        AuditWriter.write_message(conversation.conversation_id, msg["role"], msg["content"], request_time)
      end)

      # 6. Cold-store mapping merge (Turn 2+ with delta only)
      if not conversation.new? and map_size(mapping_delta) > 0 do
        AuditWriter.update_mapping(conversation.conversation_id, mapping_delta, request_time)
      end
    end

    :ok
  end

  defp do_write_conversation(conversation_id, conversation, mapping, request_time, fingerprint) do
    conv = %Conversation{
      conversation_id: conversation_id,
      source_provider: conversation.source_provider,
      provider_conversation_id: conversation.provider_conversation_id,
      fingerprint_hash: fingerprint,
      opted_out: conversation.opted_out || false,
      mapping: mapping
    }

    AuditWriter.write_conversation(conv, request_time)

    # For opted-out conversations, also cast opt_out AFTER
    # write_conversation so the tombstone UPDATE runs after the row
    # exists. The earlier opt_out cast from find_or_create may have
    # arrived before the row was created (Turn 1 mailbox ordering).
    if conversation.opted_out do
      AuditWriter.opt_out(conversation_id)
    end

    :ok
  end
end
