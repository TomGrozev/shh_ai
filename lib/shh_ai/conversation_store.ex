defmodule ShhAi.ConversationStore do
  @moduledoc """
  Behaviour and dispatch GenServer for Conversation storage backends.

  Per the storage layout in `docs/adr/0007-conversation-tracking.md`, a
  ConversationStore backend stores:

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
  @callback migrate_id(Conversation.conversation_id(), Conversation.conversation_id()) ::
              :ok | {:error, :not_found | term()}
  @callback cleanup_expired() :: non_neg_integer()
  @callback update_fingerprint(Conversation.conversation_id(), String.t()) ::
              :ok | {:error, :not_found | term()}
  @callback cache_message(Conversation.conversation_id(), String.t(), term()) ::
              :ok | {:error, term()}
  @callback lookup_message(Conversation.conversation_id(), String.t()) ::
              {:ok, term()} | {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Public API — GenServer control plane
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the configured ConversationStore backend module.

  Resolves to `ShhAi.ConversationStore.ETS` for the default `:ets`
  configuration, or to `ShhAi.ConversationStore.Redis` when configured.
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
  Moves all conversation data from `old_id` to `new_id`.

  Used for Turn 1 migration from a temporary UUID v4 to a deterministic
  UUID v5. The old conversation and all its associated state (mapping,
  reverse index) are transferred to `new_id` and the old entries are
  deleted.

  Returns `:ok` on success, `{:error, :not_found}` if no conversation
  with `old_id` exists.
  """
  @spec migrate_id(Conversation.conversation_id(), Conversation.conversation_id()) ::
          :ok | {:error, :not_found | term()}
  def migrate_id(old_id, new_id) do
    backend().migrate_id(old_id, new_id)
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

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    backend =
      case Config.conversation_store_backend() do
        :ets ->
          schedule_cleanup()
          ShhAi.ConversationStore.ETS

        :redis ->
          ShhAi.ConversationStore.Redis
      end

    case backend.init() do
      :ok ->
        {:ok, %{backend: backend}}

      other ->
        Logger.error("ConversationStore backend init failed: #{inspect(other)}")
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

  defp do_cleanup(ShhAi.ConversationStore.ETS) do
    ShhAi.ConversationStore.ETS.cleanup_expired()
  rescue
    e ->
      Logger.error("Conversation cleanup failed: #{inspect(e)}")
      0
  end

  # Redis handles TTL automatically; the cleanup is a no-op.
  defp do_cleanup(_redis_backend), do: :ok
end
