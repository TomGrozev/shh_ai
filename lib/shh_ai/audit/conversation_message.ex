defmodule ShhAi.Audit.ConversationMessage do
  @moduledoc """
  Ecto schema for the `conversation_messages` audit table.

  Each row represents one sanitized message written to the audit
  database. The `sanitized_content` column is encrypted via
  `ShhAi.Audit.Vault`. `created_at` reflects the actual request
  time (passed from the facade at call site).

  See ADR 0010.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "conversation_messages" do
    field(:conversation_id, :string)
    field(:role, :string)
    field(:sanitized_content, ShhAi.Audit.Types.EncryptedBinary)
    field(:created_at, :naive_datetime)
  end

  @required [
    :conversation_id,
    :role,
    :sanitized_content,
    :created_at
  ]

  @doc """
  Changeset for inserting a new conversation message.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, @required)
    |> validate_required(@required)
  end
end
