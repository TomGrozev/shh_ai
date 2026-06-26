defmodule ShhAi.Repo.Migrations.CreateEventsTable do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :text, primary_key: true
      add :started_at, :naive_datetime, null: false
      add :ended_at, :naive_datetime, null: false
      add :duration_ms, :real, null: false
      add :source_provider, :text, null: false
      add :target_provider, :text, null: false
      add :request_path, :text
      add :method, :text
      add :streaming, :boolean, null: false, default: false
      add :status, :integer
      add :conversation_id, :text
      add :pii_detected_count, :integer, null: false
      add :pii_sanitized_count, :integer, null: false
      add :pii_preserved_count, :integer, null: false
      add :pii_types, :text, null: false
      add :timings, :text, null: false
      add :error, :text
      add :inserted_at, :naive_datetime, null: false
    end

    create index(:events, [:conversation_id])
    create index(:events, [:inserted_at])
  end
end
