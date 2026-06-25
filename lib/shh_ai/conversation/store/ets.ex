defmodule ShhAi.Conversation.Store.ETS do
  @moduledoc """
  ETS-based storage backend for Conversations.

  Implements the `ShhAi.Conversation.Store` behaviour using three named
  ETS tables laid out per `docs/adr/0007-conversation-tracking.md`:

    * `:conversations` — `{conversation_id, source_provider, created_at,
      last_active_at, provider_conversation_id, fingerprint_hash,
      opted_out}`. Keyed by `conversation_id`. The 7th element
      (`opted_out`) is the Audit Mode opt-out flag — set per request from
      the `X-No-Audit` header. Defaults to `false`; preserved through
      `touch/1` and `update_fingerprint/2` so the sliding TTL and
      fingerprint refresh do not clobber the opt-out state.
    * `:conversation_mappings` — `{{conversation_id, placeholder_key},
      original_value}`. Atomic placeholder assignment via
      `:ets.insert_new/2`.
    * `:conversation_reverse_index` —
      `{{conversation_id, original_value, pii_type}, placeholder_key}`.
      O(1) reverse lookup so the sanitizer can reuse an existing
      placeholder for a previously-seen `{original_value, type}` pair.
  """

  @behaviour ShhAi.Conversation.Store

  alias ShhAi.Config

  @impl true
  def init do
    [
      :conversations,
      :conversation_mappings,
      :conversation_reverse_index,
      :conversation_message_cache
    ]
    |> Enum.each(&create_table/1)

    :ok
  end

  @impl true
  def create(conversation) do
    :ets.insert(
      :conversations,
      {conversation.conversation_id, conversation.source_provider, conversation.created_at,
       conversation.last_active_at, conversation.provider_conversation_id,
       conversation.fingerprint_hash, Map.get(conversation, :opted_out, false) || false}
    )

    :ok
  end

  @impl true
  def add_mapping(conversation_id, mapping_entries, reverse_index_entries) do
    Enum.each(mapping_entries, fn {placeholder_key, original_value} ->
      # `insert_new` is the atomic placeholder assignment: first writer wins,
      # second writer's insert is a no-op. This is the key invariant — once
      # `EMAIL_1` is bound to "john@example.com" in a Conversation, a later
      # request that also detects "john@example.com" must reuse `EMAIL_1`
      # rather than assign a fresh placeholder.
      :ets.insert_new(
        :conversation_mappings,
        {{conversation_id, placeholder_key}, original_value}
      )
    end)

    Enum.each(reverse_index_entries, fn {{original_value, pii_type}, placeholder_key} ->
      :ets.insert_new(
        :conversation_reverse_index,
        {{conversation_id, original_value, pii_type}, placeholder_key}
      )
    end)

    :ok
  end

  @impl true
  def get_mapping(conversation_id) do
    with :ok <- conversation_exists?(conversation_id) do
      mapping =
        :ets.match_object(:conversation_mappings, {{conversation_id, :_}, :_})
        |> Map.new(fn {{_conv_id, placeholder_key}, original_value} ->
          {placeholder_key, original_value}
        end)

      {:ok, mapping}
    end
  end

  @impl true
  def get_reverse_index(conversation_id) do
    with :ok <- conversation_exists?(conversation_id) do
      reverse_index =
        :ets.match_object(
          :conversation_reverse_index,
          {{conversation_id, :_, :_}, :_}
        )
        |> Map.new(fn {{_conv_id, original_value, pii_type}, placeholder_key} ->
          {{original_value, pii_type}, placeholder_key}
        end)

      {:ok, reverse_index}
    end
  end

  @impl true
  def lookup_placeholder(conversation_id, original_value, pii_type) do
    with :ok <- conversation_exists?(conversation_id) do
      case :ets.lookup(
             :conversation_reverse_index,
             {conversation_id, original_value, pii_type}
           ) do
        [{_, placeholder_key}] -> {:ok, placeholder_key}
        [] -> {:error, :not_found}
      end
    end
  end

  @impl true
  def touch(conversation_id) do
    case :ets.lookup(:conversations, conversation_id) do
      [
        {_, source_provider, created_at, _old_last_active, provider_conversation_id,
         fingerprint_hash, opted_out}
      ] ->
        now = System.monotonic_time(:millisecond)

        # `:ets.insert/2` overwrites the existing tuple in-place — the
        # other fields (source_provider, created_at, provider_conversation_id,
        # fingerprint_hash, opted_out) are preserved; only last_active_at
        # is bumped. This refreshes the sliding TTL clock per ADR 0007.
        # The opt-out flag must NOT be reset on touch — it is the
        # request-scoped signal that persists for the life of the
        # conversation.
        :ets.insert(
          :conversations,
          {conversation_id, source_provider, created_at, now, provider_conversation_id,
           fingerprint_hash, opted_out}
        )

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def get_conversation(conversation_id) do
    case :ets.lookup(:conversations, conversation_id) do
      [
        {^conversation_id, source_provider, created_at, last_active_at, provider_conversation_id,
         fingerprint_hash, opted_out}
      ] ->
        {:ok, mapping} = get_mapping(conversation_id)
        {:ok, reverse_index} = get_reverse_index(conversation_id)

        {:ok,
         %ShhAi.Conversation{
           conversation_id: conversation_id,
           source_provider: source_provider,
           created_at: created_at,
           last_active_at: last_active_at,
           provider_conversation_id: provider_conversation_id,
           fingerprint_hash: fingerprint_hash,
           opted_out: opted_out,
           mapping: mapping,
           reverse_index: reverse_index,
           new?: false
         }}

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def update_fingerprint(conversation_id, fingerprint_hash) do
    case :ets.lookup(:conversations, conversation_id) do
      [
        {^conversation_id, source_provider, created_at, last_active_at, provider_conversation_id,
         _old_hash, opted_out}
      ] ->
        # The opt-out flag is preserved through a fingerprint refresh —
        # it is the request-scoped signal for the whole conversation, not
        # something tied to a particular fingerprint value.
        :ets.insert(
          :conversations,
          {conversation_id, source_provider, created_at, last_active_at, provider_conversation_id,
           fingerprint_hash, opted_out}
        )

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def delete(conversation_id) do
    # `:ets.delete/2` on a missing key is a no-op (returns `true` when the
    # key existed, `false` otherwise) — making `delete/1` naturally
    # idempotent. The `match_delete/2` calls also tolerate missing keys.
    :ets.delete(:conversations, conversation_id)
    :ets.match_delete(:conversation_mappings, {{conversation_id, :_}, :_})
    :ets.match_delete(:conversation_reverse_index, {{conversation_id, :_, :_}, :_})
    :ets.match_delete(:conversation_message_cache, {{conversation_id, :_}, :_})
    :ok
  end

  @impl true
  def cache_message(conversation_id, message_hash, sanitized_content) do
    :ets.insert(
      :conversation_message_cache,
      {{conversation_id, message_hash}, sanitized_content}
    )

    :ok
  end

  @impl true
  def lookup_message(conversation_id, message_hash) do
    case :ets.lookup(:conversation_message_cache, {conversation_id, message_hash}) do
      [{_, sanitized_content}] -> {:ok, sanitized_content}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_opted_out(conversation_id) do
    case :ets.lookup(:conversations, conversation_id) do
      [{_, _, _, _, _, _, opted_out}] -> opted_out
      [] -> false
    end
  end

  @impl true
  def set_opted_out(conversation_id) do
    case :ets.lookup(:conversations, conversation_id) do
      [{_, _, _, _, _, _, true}] ->
        # Already opted out — no-op (sticky: only false → true).
        :ok

      [
        {conversation_id, source_provider, created_at, last_active_at, provider_conversation_id,
         fingerprint_hash, false}
      ] ->
        # Transition from false → true. This is intentional — once opted
        # out, a conversation can never be opted back in.
        :ets.insert(
          :conversations,
          {conversation_id, source_provider, created_at, last_active_at, provider_conversation_id,
           fingerprint_hash, true}
        )

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def list_conversations(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    :conversations
    |> :ets.tab2list()
    |> Enum.sort_by(
      fn {_, _, _, last_active_at, _, _, _} -> last_active_at end,
      :desc
    )
    |> Enum.take(limit)
    |> Enum.map(fn {conversation_id, source_provider, created_at, last_active_at,
                    provider_conversation_id, fingerprint_hash, opted_out} ->
      {:ok, mapping} = get_mapping(conversation_id)
      {:ok, reverse_index} = get_reverse_index(conversation_id)

      %ShhAi.Conversation{
        conversation_id: conversation_id,
        source_provider: source_provider,
        created_at: created_at,
        last_active_at: last_active_at,
        provider_conversation_id: provider_conversation_id,
        fingerprint_hash: fingerprint_hash,
        opted_out: opted_out,
        mapping: mapping,
        reverse_index: reverse_index,
        new?: false
      }
    end)
  end

  @impl true
  def cleanup_expired do
    # Behaviour callback — reads the configured TTL from
    # Config.conversation_ttl/0 (Slice 10). Delegates to the testable /1
    # variant.
    cleanup_expired(Config.conversation_ttl())
  end

  @doc """
  Testable variant of `cleanup_expired/0` that takes an explicit sliding
  TTL in milliseconds. The GenServer in `ShhAi.Conversation.Store` invokes
  `cleanup_expired/0`; tests use this overload to assert eviction
  behaviour without waiting an hour for the default TTL to elapse.

  Returns the number of Conversations evicted.
  """
  @spec cleanup_expired(non_neg_integer()) :: non_neg_integer()
  def cleanup_expired(ttl_ms) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - ttl_ms

    # Find expired conversation IDs. The match spec projects only the
    # conversation_id (the first element of the tuple) when the
    # last_active_at (fourth element) is strictly less than the cutoff.
    # The 7th element (opted_out) is matched as :_ — cleanup is
    # independent of audit opt-out state.
    expired_ids =
      :ets.select(:conversations, [
        {{:"$1", :_, :_, :"$2", :_, :_, :_}, [{:<, :"$2", cutoff}], [:"$1"]}
      ])

    # Evict each expired Conversation, including all of its associated
    # mapping and reverse-index rows. Delegates to `delete/1` so the
    # eviction logic lives in exactly one place.
    Enum.each(expired_ids, &delete/1)

    length(expired_ids)
  end

  # Private helpers

  # Returns :ok if the conversation exists in the :conversations table,
  # {:error, :not_found} otherwise. Used by get_mapping/1 and
  # get_reverse_index/1 to distinguish "no mapping yet" from "no such
  # conversation" (a row with an empty mapping is a valid state, not a
  # not-found).
  defp conversation_exists?(conversation_id) do
    case :ets.lookup(:conversations, conversation_id) do
      [] -> {:error, :not_found}
      _ -> :ok
    end
  end

  # Creates a named, set-type ETS table. Idempotent — re-initialising
  # is a no-op when the table already exists.
  #
  # Note: Tables use :public access because they're accessed from multiple processes
  # (Conversation.Store GenServer, request handlers, cleanup tasks). This is necessary
  # for the concurrent access pattern.
  defp create_table(name) do
    case :ets.info(name) do
      :undefined ->
        :ets.new(name, [
          :set,
          :public,
          :named_table,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      _ ->
        :ok
    end
  end
end
