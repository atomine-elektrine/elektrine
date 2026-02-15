defmodule Elektrine.Repo.Migrations.AddCallsTable do
  use Ecto.Migration

  def change do
    create table(:calls) do
      add :caller_id, references(:users, on_delete: :delete_all), null: false
      add :callee_id, references(:users, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, on_delete: :delete_all)
      # "audio" or "video"
      add :call_type, :string, null: false
      # "initiated", "ringing", "active", "ended", "rejected", "missed", "failed"
      add :status, :string, null: false
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
      # Calculated duration in seconds
      add :duration_seconds, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:calls, [:caller_id])
    create index(:calls, [:callee_id])
    create index(:calls, [:conversation_id])
    create index(:calls, [:inserted_at])
    create index(:calls, [:status])
  end
end
