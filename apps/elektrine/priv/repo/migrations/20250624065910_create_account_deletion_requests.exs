defmodule Elektrine.Repo.Migrations.CreateAccountDeletionRequests do
  use Ecto.Migration

  def change do
    create table(:account_deletion_requests) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :reason, :text
      add :status, :string, default: "pending", null: false
      add :requested_at, :utc_datetime, null: false
      add :reviewed_at, :utc_datetime
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :admin_notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:account_deletion_requests, [:user_id])
    create index(:account_deletion_requests, [:status])
    create index(:account_deletion_requests, [:requested_at])
  end
end
