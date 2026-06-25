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

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:write_conversation, conv, request_time}, state) do
    if Config.audit_mode?() do
      do_write_conversation(conv, request_time)
    end

    {:noreply, state}
  end

  def handle_cast({:update_mapping, conversation_id, new_mapping, request_time}, state) do
    if Config.audit_mode?() and not Store.get_opted_out(conversation_id) do
      do_update_mapping(conversation_id, new_mapping, request_time)
    end

    {:noreply, state}
  end

  def handle_cast({:write_message, conversation_id, role, sanitized_content, request_time}, state) do
    if Config.audit_mode?() and not Store.get_opted_out(conversation_id) do
      do_write_message(conversation_id, role, sanitized_content, request_time)
    end

    {:noreply, state}
  end

  def handle_cast({:opt_out, conversation_id}, state) do
    if Config.audit_mode?() do
      do_opt_out(conversation_id)
    end

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
end
