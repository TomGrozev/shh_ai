defmodule ShhAi.Repo.Migrations.CreateAuditTables do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :conversation_id, :text, primary_key: true
      add :source_provider, :text, null: false
      add :provider_conversation_id, :text
      add :fingerprint_hash, :text, null: false
      add :opted_out, :boolean, null: false, default: false
      add :mapping, :binary
      add :created_at, :naive_datetime, null: false
      add :last_active_at, :naive_datetime, null: false
    end

    create table(:conversation_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, :text, null: false
      add :role, :text, null: false
      add :sanitized_content, :binary
      add :created_at, :naive_datetime, null: false
    end

    create index(:conversation_messages, [:conversation_id])
  end
end
