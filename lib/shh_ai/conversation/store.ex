defmodule ShhAi.Conversation.Store do
  @moduledoc """
  Behaviour and dispatch GenServer for Conversation storage backends.

  Per the storage layout in `docs/adr/0007-conversation-tracking.md`, a
  Conversation.Store backend stores:

    * Conversation metadata (`source_provider`, `created_at`,
      `last_active_at`, `fingerprint_hash`, `provider_conversation_id`)
    * The accumulated PII Mapping (`placeholder → original`) per Conversation
    * The Reverse Index (`{original_value, type} → placeholder`) per Conversation

  ## Backend dispatch

  The backend is chosen at boot from `ShhAi.Config.conversation_store_backend/0`.
  The chosen backend is captured in the GenServer's state and returned by
  `backend/0`; all per-request delegate functions route through that backend.
  """

  use GenServer

  require Logger

  alias ShhAi.Config
  alias ShhAi.Conversation
  alias ShhAi.Conversation.Store.ETS

  # Periodic cleanup cadence (10s interval).
  @cleanup_interval 10_000

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @callback init() :: :ok
  @callback create(Conversation.t()) ::
              :ok | {:error, term()}
  @callback add_mapping(
              Conversation.conversation_id(),
              Conversation.mapping(),
              Conversation.reverse_index()
            ) ::
              :ok | {:error, term()}
  @callback get_mapping(Conversation.conversation_id()) ::
              {:ok, Conversation.mapping()} | {:error, :not_found}
  @callback get_reverse_index(Conversation.conversation_id()) ::
              {:ok, Conversation.reverse_index()} | {:error, :not_found}
  @callback lookup_placeholder(Conversation.conversation_id(), String.t(), atom()) ::
              {:ok, String.t()} | {:error, :not_found}
  @callback touch(Conversation.conversation_id()) :: :ok | {:error, :not_found}
  @callback delete(Conversation.conversation_id()) :: :ok
  @callback get_conversation(Conversation.conversation_id()) ::
              {:ok, Conversation.t()} | {:error, :not_found}
  @callback cleanup_expired() :: non_neg_integer()
  @callback update_fingerprint(Conversation.conversation_id(), String.t()) ::
              :ok | {:error, :not_found | term()}
  @callback cache_message(Conversation.conversation_id(), String.t(), term()) ::
              :ok | {:error, term()}
  @callback lookup_message(Conversation.conversation_id(), String.t()) ::
              {:ok, term()} | {:error, :not_found}
  @callback list_conversations(keyword()) :: [Conversation.t()]

  @doc """
  Returns the `opted_out` flag for a Conversation from the store
  backend. This is a lightweight read (no mapping/reverse_index fetch).
  Returns `false` if the conversation does not exist.
  """
  @callback get_opted_out(Conversation.conversation_id()) :: boolean()

  @doc """
  Sets the `opted_out` flag to `true` on an existing Conversation.
  Sticky — only transitions from `false` to `true`; a call on an
  already-opted-out conversation is a no-op. Returns `:ok` on success,
  `{:error, :not_found}` if the conversation does not exist.
  """
  @callback set_opted_out(Conversation.conversation_id()) :: :ok | {:error, :not_found}

  @doc """
  Flips the `opted_out` flag to `true` on an existing Conversation.
  Unlike `set_opted_out/1`, this function is called as a result of a
  confirmed persisted opt-out (sync SQLite read found a tombstone) and
  does not check the current value — it unconditionally sets opted_out
  to `true`. Returns `:ok` on success, `{:error, :not_found}` if the
  conversation does not exist.
  """
  @callback mark_opted_out(Conversation.conversation_id()) :: :ok | {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Public API — GenServer control plane
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the configured Conversation.Store backend module.

  Resolves to `ShhAi.Conversation.Store.ETS` for the default `:ets`
  configuration, or to `ShhAi.Conversation.Store.Redis` when configured.
  """
  @spec backend() :: module()
  def backend do
    GenServer.call(__MODULE__, :backend)
  end

  @doc """
  Manually trigger a cleanup pass. Returns the number of Conversations
  removed (or `:ok` for backends like Redis that handle TTL automatically).
  Useful from tests and from a future admin endpoint.
  """
  @spec cleanup() :: non_neg_integer() | :ok
  def cleanup do
    GenServer.call(__MODULE__, :cleanup)
  end

  # ---------------------------------------------------------------------------
  # Public API — delegate functions
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new Conversation with the given attributes. Returns the
  freshly-created `Conversation.t()`.
  """
  @spec create(Conversation.t()) :: :ok | {:error, term()}
  def create(conversation) do
    backend().create(conversation)
  end

  @doc """
  Atomically adds new mapping and reverse-index entries to a Conversation.
  """
  @spec add_mapping(
          Conversation.conversation_id(),
          Conversation.mapping(),
          Conversation.reverse_index()
        ) ::
          :ok | {:error, term()}
  def add_mapping(conversation_id, mapping_entries, reverse_index_entries) do
    backend().add_mapping(conversation_id, mapping_entries, reverse_index_entries)
  end

  @doc """
  Returns the accumulated PII mapping for a Conversation.
  """
  @spec get_mapping(Conversation.conversation_id()) ::
          {:ok, Conversation.mapping()} | {:error, :not_found}
  def get_mapping(conversation_id) do
    backend().get_mapping(conversation_id)
  end

  @doc """
  Returns the reverse index for a Conversation.
  """
  @spec get_reverse_index(Conversation.conversation_id()) ::
          {:ok, Conversation.reverse_index()} | {:error, :not_found}
  def get_reverse_index(conversation_id) do
    backend().get_reverse_index(conversation_id)
  end

  @doc """
  Looks up the placeholder key assigned to a previously-seen
  `{original_value, pii_type}` pair in a Conversation's reverse index.
  """
  @spec lookup_placeholder(Conversation.conversation_id(), String.t(), atom()) ::
          {:ok, String.t()} | {:error, :not_found}
  def lookup_placeholder(conversation_id, original_value, pii_type) do
    backend().lookup_placeholder(conversation_id, original_value, pii_type)
  end

  @doc """
  Resets the Conversation's sliding TTL clock. Called on each new request
  within the Conversation.
  """
  @spec touch(Conversation.conversation_id()) :: :ok | {:error, :not_found}
  def touch(conversation_id) do
    backend().touch(conversation_id)
  end

  @doc """
  Returns the full `Conversation.t()` struct for the given ID, including
  the accumulated mapping and reverse index. Returns `{:error, :not_found}`
  if no Conversation with that ID exists.
  """
  @spec get_conversation(Conversation.conversation_id()) ::
          {:ok, Conversation.t()} | {:error, :not_found}
  def get_conversation(conversation_id) do
    backend().get_conversation(conversation_id)
  end

  @doc """
  Deletes a Conversation and all its accumulated state (mapping, reverse
  index, and — in later slices — message cache and fingerprint entry).
  """
  @spec delete(Conversation.conversation_id()) :: :ok
  def delete(conversation_id) do
    backend().delete(conversation_id)
  end

  @doc """
  Updates the fingerprint hash for an existing Conversation.

  Called after Turn 2+ when the full message history changes and the
  fingerprint needs to be refreshed. Returns `:ok` on success,
  `{:error, :not_found}` if no conversation with the given ID exists.
  """
  @spec update_fingerprint(Conversation.conversation_id(), String.t()) ::
          :ok | {:error, :not_found | term()}
  def update_fingerprint(conversation_id, fingerprint_hash) do
    backend().update_fingerprint(conversation_id, fingerprint_hash)
  end

  @doc """
  Caches sanitized message content keyed by `{conversation_id, message_hash}`.

  The `sanitized_content` is stored as an opaque `term()`. Returns `:ok` on
  success.
  """
  @spec cache_message(Conversation.conversation_id(), String.t(), term()) ::
          :ok | {:error, term()}
  def cache_message(conversation_id, message_hash, sanitized_content) do
    backend().cache_message(conversation_id, message_hash, sanitized_content)
  end

  @doc """
  Looks up previously cached sanitized message content.

  Returns `{:ok, sanitized_content}` if found, `{:error, :not_found}` otherwise.
  """
  @spec lookup_message(Conversation.conversation_id(), String.t()) ::
          {:ok, term()} | {:error, :not_found}
  def lookup_message(conversation_id, message_hash) do
    backend().lookup_message(conversation_id, message_hash)
  end

  @doc """
  Lists conversations, sorted by last_active_at descending (most recent first).

  ## Options
    * `:limit` - maximum number of conversations to return (default: 50)
  """
  @spec list_conversations(keyword()) :: [Conversation.t()]
  def list_conversations(opts \\ []) do
    backend = backend()
    backend.list_conversations(opts)
  end

  @doc """
  Returns the `opted_out` flag for a Conversation. Lightweight read —
  no mapping or reverse index fetch. Returns `false` if the conversation
  does not exist.
  """
  @spec get_opted_out(Conversation.conversation_id()) :: boolean()
  def get_opted_out(conversation_id) do
    backend().get_opted_out(conversation_id)
  end

  @doc """
  Sets `opted_out = true` on an existing Conversation. Sticky — only
  transitions from `false` to `true`; a call on an already-opted-out
  conversation is a no-op. Returns `{:error, :not_found}` if the
  conversation does not exist.
  """
  @spec set_opted_out(Conversation.conversation_id()) :: :ok | {:error, :not_found}
  def set_opted_out(conversation_id) do
    backend().set_opted_out(conversation_id)
  end

  @doc """
  Unconditionally sets `opted_out = true` on an existing Conversation.
  Called as a result of a confirmed persisted opt-out (sync SQLite read
  found a tombstone). Unlike `set_opted_out/1`, this does not check
  the current value — it always writes `true`. Returns `:ok` on
  success, `{:error, :not_found}` if the conversation does not exist.
  """
  @spec mark_opted_out(Conversation.conversation_id()) :: :ok | {:error, :not_found}
  def mark_opted_out(conversation_id) do
    backend().mark_opted_out(conversation_id)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    backend =
      case Config.conversation_store_backend() do
        :ets ->
          schedule_cleanup()
          ShhAi.Conversation.Store.ETS

        :redis ->
          ShhAi.Conversation.Store.Redis
      end

    case backend.init() do
      :ok ->
        {:ok, %{backend: backend}}

      other ->
        Logger.error("Conversation.Store backend init failed: #{inspect(other)}")
        {:stop, {:backend_init_failed, other}}
    end
  end

  @impl true
  def handle_info(:cleanup, %{backend: backend} = state) do
    do_cleanup(backend)
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_call(:backend, _from, %{backend: backend} = state) do
    {:reply, backend, state}
  end

  def handle_call(:cleanup, _from, %{backend: backend} = state) do
    {:reply, do_cleanup(backend), state}
  end

  # Private helpers

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp do_cleanup(ETS) do
    ETS.cleanup_expired()
  rescue
    e ->
      Logger.error("Conversation cleanup failed: #{inspect(e)}")
      0
  end

  # Redis handles TTL automatically; the cleanup is a no-op.
  defp do_cleanup(_redis_backend), do: :ok
end
