defmodule Elektrine.Repo.Migrations.DropSubscriptionsTable do
  use Ecto.Migration

  def up do
    drop_if_exists table(:subscriptions)
  end

  def down do
    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :plan, :string, null: false
      add :status, :string, null: false, default: "active"
      add :expires_at, :utc_datetime, null: false

      timestamps()
    end

    create index(:subscriptions, [:user_id])
    create index(:subscriptions, [:status])
    create index(:subscriptions, [:expires_at])
    create index(:subscriptions, [:user_id, :status])
  end
end
