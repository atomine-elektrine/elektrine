defmodule Elektrine.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
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
