defmodule ShhAi.Audit.ConversationRecord do
  @moduledoc """
  Ecto schema for the `conversations` audit table.

  Maps the Audit Mode conversation metadata including the encrypted
  `mapping` column (PII placeholder → original value mapping, encrypted
  via `ShhAi.Audit.Vault`).

  The `conversation_id` is the primary key (UUID v5 derived from the
  fingerprint). `created_at` and `last_active_at` reflect the actual
  request time (not the Writer's processing time) — the facade passes
  the timestamp from the call site.

  See ADR 0010.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:conversation_id, :string, autogenerate: false}
  @foreign_key_type :binary_id

  schema "conversations" do
    field(:source_provider, :string)
    field(:provider_conversation_id, :string)
    field(:fingerprint_hash, :string)
    field(:opted_out, :boolean, default: false)
    field(:mapping, ShhAi.Audit.Types.EncryptedBinary)
    field(:created_at, :naive_datetime)
    field(:last_active_at, :naive_datetime)
  end

  @required [
    :conversation_id,
    :source_provider,
    :fingerprint_hash,
    :created_at,
    :last_active_at
  ]

  @doc """
  Changeset for inserting a new conversation.
  """
  def insert_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, @required ++ [:provider_conversation_id, :opted_out, :mapping])
    |> validate_required(@required)
  end

  @doc """
  Changeset for updating an existing conversation's mapping.
  Only allows updating the `mapping` and `last_active_at` fields.
  """
  def mapping_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:mapping, :last_active_at])
    |> validate_required([:mapping, :last_active_at])
  end

  @doc """
  Builds a changeset from a `%ShhAi.Conversation{}` struct and a
  `NaiveDateTime` timestamp. Used by the Writer to create a cold-store
  row from the hot-store conversation.
  """
  @spec from_conversation(ShhAi.Conversation.t(), NaiveDateTime.t()) :: Ecto.Changeset.t()
  def from_conversation(%ShhAi.Conversation{} = conv, %NaiveDateTime{} = request_time) do
    mapping_binary =
      case conv.mapping do
        %{} = map when map_size(map) == 0 -> nil
        %{} = map -> :erlang.term_to_binary(map)
        other -> other
      end

    attrs = %{
      conversation_id: conv.conversation_id,
      source_provider: to_string(conv.source_provider),
      provider_conversation_id: conv.provider_conversation_id,
      fingerprint_hash: conv.fingerprint_hash || "",
      opted_out: conv.opted_out || false,
      mapping: mapping_binary,
      created_at: request_time,
      last_active_at: request_time
    }

    %__MODULE__{}
    |> cast(attrs, [
      :conversation_id,
      :source_provider,
      :provider_conversation_id,
      :fingerprint_hash,
      :opted_out,
      :mapping,
      :created_at,
      :last_active_at
    ])
    |> validate_required(@required)
  end
end
