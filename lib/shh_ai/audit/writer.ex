defmodule ShhAi.Audit.Writer do
  @moduledoc """
  Fire-and-forget write GenServer for the Audit Mode data plane.

  The Writer turns synchronous data-plane events from the `Conversation`
  facade into non-blocking UPSERTs / INSERTs against the `conversations`
  and `conversation_messages` SQLite tables. Producers call the typed
  public functions (`write_conversation/2`, `write_message/4`,
  `update_mapping/3`); consumers (the GenServer) drain the mailbox and
  execute the writes in order. The Writer is intentionally single-process
  to preserve write ordering per conversation and to keep the SQLite
  writer contention predictable.

  ## Defence in depth

  Every cast handler early-bails on `Config.audit_mode?/0 == false`,
  and `write_message` / `update_mapping` additionally check the
  per-conversation `opted_out` flag via `Store.get_opted_out/1`. The
  Conversation facade also gates every cast, so an unconfigured path
  cannot leak data into the audit DB.

  ## Reactivation sync read

  When ETS has `opted_out = false` (a fresh entry after expiry or
  restart), the Writer performs a synchronous SQLite read to check the
  persisted `opted_out` flag before writing. This handles the case
  where a tombstone exists in SQLite but the ETS entry expired. If the
  sync read finds a tombstone, the Writer updates ETS via
  `Store.mark_opted_out/1` and skips the write. When ETS already has
  `opted_out = true`, no sync read is needed and the Writer
  early-bails cheaply.

  ## Retention cleanup

  The Writer runs a periodic cleanup task that deletes audit data older
  than `Config.audit_retention_days/0` (default 30 days). The interval
  is configured via `Config.audit_cleanup_interval/0` (default 1 hour).
  When Audit Mode is off the cleanup is a no-op. The retention period
  is read fresh at each cleanup cycle (not cached at boot).

  ## Timestamps

  All public functions accept a `request_time :: NaiveDateTime` parameter. The
  facade generates this at the call site so that audit rows record the
  actual request time, not the time the Writer processes the cast (the
  Writer's mailbox may be backed up).

  See ADR 0010.
  """

  use GenServer

  require Logger

  import Ecto.Changeset, only: [get_field: 2]
  import Ecto.Query

  alias ShhAi.Audit.ConversationRecord
  alias ShhAi.Audit.ConversationMessage
  alias ShhAi.Audit.EventRecord
  alias ShhAi.Config
  alias ShhAi.Conversation.Store
  alias ShhAi.Repo

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fire-and-forget UPSERT of a conversation row (including the
  encrypted mapping). Accepts a `%ShhAi.Conversation{}` struct and a
  `NaiveDateTime` timestamp; builds the cold-store changeset via
  `ConversationRecord.from_conversation/2`.

  The `on_conflict` clause updates all fields except `conversation_id`
  and `created_at` (we don't want to clobber the original creation
  time on a re-insert).
  """
  @spec write_conversation(ShhAi.Conversation.t(), NaiveDateTime.t()) :: :ok
  def write_conversation(%ShhAi.Conversation{} = conv, %NaiveDateTime{} = request_time) do
    GenServer.cast(__MODULE__, {:write_conversation, conv, request_time})
  end

  @doc """
  Fire-and-forget UPSERT of the mapping column for an existing
  conversation. Fetches the current mapping from the audit row,
  merges in the new entries, and writes back.
  """
  @spec update_mapping(String.t(), map(), NaiveDateTime.t()) :: :ok
  def update_mapping(conversation_id, new_mapping, request_time) do
    GenServer.cast(__MODULE__, {:update_mapping, conversation_id, new_mapping, request_time})
  end

  @doc """
  Fire-and-forget INSERT of an encrypted message row.
  """
  @spec write_message(String.t(), String.t(), String.t(), NaiveDateTime.t()) :: :ok
  def write_message(conversation_id, role, sanitized_content, request_time) do
    GenServer.cast(
      __MODULE__,
      {:write_message, conversation_id, role, sanitized_content, request_time}
    )
  end

  @doc """
  Fire-and-forget tombstone write for an opted-out conversation.
  UPSERTs the `conversations` row with `opted_out = true` and
  `mapping = NULL`, then deletes all `conversation_messages` rows
  for the conversation.
  """
  @spec opt_out(String.t()) :: :ok
  def opt_out(conversation_id) do
    GenServer.cast(__MODULE__, {:opt_out, conversation_id})
  end

  @doc """
  Fire-and-forget INSERT of a request metrics event.

  Accepts a `%ShhAi.Metrics.Event{}` struct. The `pii_types`, `timings`,
  and `error` fields are JSON-encoded before storage. When Audit Mode is
  off the cast is a no-op; events remain in the in-memory
  `ShhAi.Metrics.EventBuffer` ETS table only.

  Unlike conversation and message writes, `write_event/1` does NOT check
  the per-conversation `opted_out` flag — events are request-level
  metadata (timing, PII counts, status) and contain no PII content.

  See ADR 0010 / issue #25.
  """
  @spec write_event(ShhAi.Metrics.Event.t()) :: :ok
  def write_event(%ShhAi.Metrics.Event{} = event) do
    GenServer.cast(__MODULE__, {:write_event, event})
  end

  @doc """
  Synchronous trigger for the retention cleanup pass. Blocks until
  the cleanup completes (or times out after 5 seconds). Useful for
  tests and operators who want to force an immediate cleanup pass
  without waiting for the periodic timer.
  """
  @spec run_cleanup() :: :ok
  def run_cleanup do
    GenServer.call(__MODULE__, :cleanup, 5_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    interval_ms = Config.audit_cleanup_interval() * 3_600_000
    schedule_cleanup(interval_ms)
    {:ok, %{cleanup_interval_ms: interval_ms}}
  end

  @impl true
  def handle_cast({:write_conversation, conv, request_time}, state) do
    if Config.audit_mode?() do
      case check_tombstone_on_reactivation(conv.conversation_id) do
        :ok -> do_write_conversation(conv, request_time)
        :skip -> :ok
      end
    end

    {:noreply, state}
  end

  def handle_cast({:update_mapping, conversation_id, new_mapping, request_time}, state) do
    if Config.audit_mode?() do
      case check_persisted_opt_out(conversation_id) do
        :ok -> do_update_mapping(conversation_id, new_mapping, request_time)
        :skip -> :ok
      end
    end

    {:noreply, state}
  end

  def handle_cast({:write_message, conversation_id, role, sanitized_content, request_time}, state) do
    if Config.audit_mode?() do
      case check_persisted_opt_out(conversation_id) do
        :ok -> do_write_message(conversation_id, role, sanitized_content, request_time)
        :skip -> :ok
      end
    end

    {:noreply, state}
  end

  def handle_cast({:opt_out, conversation_id}, state) do
    if Config.audit_mode?() do
      do_opt_out(conversation_id)
    end

    {:noreply, state}
  end

  def handle_cast({:write_event, event}, state) do
    if Config.audit_mode?() do
      do_write_event(event)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    if Config.audit_mode?() do
      do_cleanup_old_data()
    end

    schedule_cleanup(state.cleanup_interval_ms)
    {:noreply, state}
  end

  @impl true
  # Synchronisation point used by tests. The Writer's mailbox is FIFO
  # and casts return immediately, so a follow-up `call/2` is only
  # serviced once every earlier cast has been handled. This lets
  # tests wait for the data plane to settle before asserting against
  # the DB.
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:cleanup, _from, state) do
    if Config.audit_mode?() do
      do_cleanup_old_data()
    end

    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private — reactivation sync read
  # ---------------------------------------------------------------------------

  # Returns true when SQLite has a tombstone for this conversation
  # (opted_out = true). On a true result, also flips the ETS flag via
  # Store.mark_opted_out/1. Returns false on no row, opted_out = false,
  # or query error (with a warning log). No ETS check is performed here;
  # callers gate on Store.get_opted_out/1 first to avoid an unnecessary
  # sync read when the in-memory state is already authoritative.
  defp persisted_tombstone?(conversation_id) do
    case Repo.one(
           from(c in "conversations",
             where: c.conversation_id == ^conversation_id,
             select: c.opted_out
           )
         ) do
      val when val == true or val == 1 ->
        _ = Store.mark_opted_out(conversation_id)
        true

      _ ->
        false
    end
  rescue
    e ->
      Logger.warning("Audit.Writer persisted_tombstone? failed: #{inspect(e)}")
      false
  end

  # Defence-in-depth for update_mapping and write_message: skip when ETS
  # already has opted_out = true, or when a reactivation tombstone is
  # found in SQLite. The sync read is short-circuited by the ETS check.
  defp check_persisted_opt_out(conversation_id) do
    cond do
      Store.get_opted_out(conversation_id) -> :skip
      persisted_tombstone?(conversation_id) -> :skip
      true -> :ok
    end
  end

  # Like check_persisted_opt_out, but proceeds with the write when ETS
  # already has opted_out = true. Used by write_conversation so the
  # initial tombstone row can still be created on Turn 1.
  defp check_tombstone_on_reactivation(conversation_id) do
    cond do
      Store.get_opted_out(conversation_id) -> :ok
      persisted_tombstone?(conversation_id) -> :skip
      true -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private — write helpers
  # ---------------------------------------------------------------------------

  defp do_write_conversation(conv, request_time) do
    changeset = ConversationRecord.from_conversation(conv, request_time)

    # When opted_out is true, clear mapping so the tombstone is created
    # atomically — see ADR 0011.
    mapping_value =
      if get_field(changeset, :opted_out) do
        nil
      else
        get_field(changeset, :mapping)
      end

    Repo.insert(changeset,
      on_conflict: [
        set: [
          source_provider: get_field(changeset, :source_provider),
          provider_conversation_id: get_field(changeset, :provider_conversation_id),
          fingerprint_hash: get_field(changeset, :fingerprint_hash),
          opted_out: get_field(changeset, :opted_out),
          mapping: mapping_value,
          last_active_at: get_field(changeset, :last_active_at)
        ]
      ],
      conflict_target: :conversation_id
    )
  rescue
    e ->
      Logger.error("Audit.Writer write_conversation failed: #{inspect(e)}")
      :ok
  end

  defp do_update_mapping(conversation_id, new_mapping, request_time) do
    case Repo.get(ConversationRecord, conversation_id) do
      nil ->
        Logger.warning(
          "Audit.Writer update_mapping: no conversation #{conversation_id}, skipping"
        )

      existing ->
        # The schema's `load/1` callback already decrypted the mapping
        # column, so `existing.mapping` is either nil or the plaintext
        # binary produced by `:erlang.term_to_binary/1`.
        existing_mapping = decode_mapping(existing.mapping)
        merged = Map.merge(existing_mapping, new_mapping)
        encoded = encode_mapping(merged)

        existing
        |> ConversationRecord.mapping_changeset(%{mapping: encoded, last_active_at: request_time})
        |> Repo.update()
    end
  rescue
    e ->
      Logger.error("Audit.Writer update_mapping failed: #{inspect(e)}")
      :ok
  end

  defp do_write_message(conversation_id, role, sanitized_content, request_time) do
    %ConversationMessage{}
    |> ConversationMessage.changeset(%{
      conversation_id: conversation_id,
      role: to_string(role),
      sanitized_content: sanitized_content,
      created_at: request_time
    })
    |> Repo.insert()
  rescue
    e ->
      Logger.error("Audit.Writer write_message failed: #{inspect(e)}")
      :ok
  end

  defp do_opt_out(conversation_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    with {:ok, _} <- update_tombstone(conversation_id, now),
         {:ok, _} <- delete_messages(conversation_id) do
      :ok
    end
  rescue
    e ->
      Logger.error("Audit.Writer opt_out failed: #{inspect(e)}")
      :ok
  end

  # UPDATE-only: set opted_out, clear mapping, bump last_active_at.
  # Uses UPDATE (not UPSERT) because the row may not exist yet — for
  # Turn 1, opt_out arrives before write_conversation. The UPDATE is a
  # safe no-op when the row is absent; write_conversation will later
  # create it with opted_out = true via cast_audit_write_conversation.
  # See moduledoc / ADR 0011 for the Turn 1 race rationale.
  defp update_tombstone(conversation_id, now) do
    {rows, _} =
      ConversationRecord
      |> where([c], c.conversation_id == ^conversation_id)
      |> Repo.update_all(set: [opted_out: true, mapping: nil, last_active_at: now])

    case rows do
      0 -> log_tombstone_missing(conversation_id)
      _ -> :ok
    end

    {:ok, rows}
  end

  defp delete_messages(conversation_id) do
    {rows, _} =
      from(m in "conversation_messages", where: m.conversation_id == ^conversation_id)
      |> Repo.delete_all()

    {:ok, rows}
  end

  defp log_tombstone_missing(conversation_id) do
    Logger.info(
      "Audit.Writer opt_out: no existing conversations row for #{conversation_id}; write_conversation will create the tombstone"
    )
  end

  # Encode a mapping (Elixir map) for storage via the EncryptedBinary type.
  # The map is serialised with :erlang.term_to_binary/1 before encryption.
  # Empty maps are stored as nil (no encrypted blob).
  defp encode_mapping(nil), do: nil
  defp encode_mapping(%{} = map) when map_size(map) == 0, do: nil

  defp encode_mapping(mapping) when is_map(mapping) do
    :erlang.term_to_binary(mapping)
  end

  defp encode_mapping(other), do: other

  # Decode a mapping from the decrypted binary stored in the schema.
  # The schema's `load/1` callback already decrypted the ciphertext,
  # so this just reverses the `:erlang.term_to_binary/1` encoding.
  defp decode_mapping(nil), do: %{}

  defp decode_mapping(binary) when is_binary(binary) do
    :erlang.binary_to_term(binary)
  rescue
    ArgumentError -> %{}
  end

  defp decode_mapping(_), do: %{}

  # ---------------------------------------------------------------------------
  # Private — event write helpers
  # ---------------------------------------------------------------------------

  defp do_write_event(%ShhAi.Metrics.Event{} = event) do
    attrs = %{
      id: event.id,
      started_at: microseconds_to_naive_datetime(event.started_at),
      ended_at: microseconds_to_naive_datetime(event.ended_at),
      duration_ms: event.duration_ms,
      source_provider: to_string(event.source_provider),
      target_provider: to_string(event.target_provider),
      request_path: event.request_path,
      method: event.method,
      streaming: event.streaming,
      status: event.status,
      conversation_id: event.conversation_id,
      pii_detected_count: event.pii_detected_count,
      pii_sanitized_count: event.pii_sanitized_count,
      pii_preserved_count: event.pii_preserved_count,
      pii_types: Jason.encode!(Enum.map(event.pii_types, &Atom.to_string/1)),
      timings: Jason.encode!(event.timings),
      error: encode_error(event.error),
      inserted_at: microseconds_to_naive_datetime(event.inserted_at)
    }

    %EventRecord{}
    |> EventRecord.changeset(attrs)
    |> Repo.insert()
  rescue
    e ->
      Logger.error("Audit.Writer write_event failed: #{inspect(e)}")
      :ok
  end

  # The `ShhAi.Metrics.Event` struct stores `started_at`, `ended_at`, and
  # `inserted_at` as microsecond integers (System.system_time(:microsecond)).
  # The events table stores them as `naive_datetime`. Convert at the seam.
  defp microseconds_to_naive_datetime(us) when is_integer(us) do
    us
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
  end

  # Error maps are stored as JSON-encoded text, or NULL when absent.
  defp encode_error(nil), do: nil
  defp encode_error(%{} = error), do: Jason.encode!(error)
  defp encode_error(other), do: Jason.encode!(other)

  # ---------------------------------------------------------------------------
  # Private — retention cleanup
  # ---------------------------------------------------------------------------

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end

  defp do_cleanup_old_data do
    days = Config.audit_retention_days()

    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-days * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    {events_deleted, _} =
      from(e in "events", where: e.inserted_at < ^cutoff)
      |> Repo.delete_all()

    {messages_deleted, _} =
      from(m in "conversation_messages",
        where:
          m.conversation_id in subquery(
            from(c in "conversations", select: c.conversation_id, where: c.created_at < ^cutoff)
          )
      )
      |> Repo.delete_all()

    {conversations_deleted, _} =
      from(c in "conversations", where: c.created_at < ^cutoff)
      |> Repo.delete_all()

    if events_deleted > 0 or messages_deleted > 0 or conversations_deleted > 0 do
      Logger.info(
        "Audit.Writer cleanup: deleted #{events_deleted} events, #{messages_deleted} messages, #{conversations_deleted} conversations (retention=#{days}d)"
      )
    end

    :ok
  rescue
    e ->
      Logger.error("Audit.Writer cleanup failed: #{inspect(e)}")
      :ok
  end
end
