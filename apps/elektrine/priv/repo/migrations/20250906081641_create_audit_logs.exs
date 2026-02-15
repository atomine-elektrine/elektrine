defmodule Elektrine.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs) do
      add :admin_id, references(:users, on_delete: :nilify_all), null: false
      add :target_user_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :integer
      add :details, :map
      add :ip_address, :string
      add :user_agent, :string

      timestamps()
    end

    create index(:audit_logs, [:admin_id])
    create index(:audit_logs, [:target_user_id])
    create index(:audit_logs, [:action])
    create index(:audit_logs, [:resource_type])
    create index(:audit_logs, [:inserted_at])
    create index(:audit_logs, [:admin_id, :inserted_at])
  end
end
