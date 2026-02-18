defmodule Elektrine.Repo.Migrations.CreateEmailSuppressions do
  use Ecto.Migration

  def change do
    create table(:email_suppressions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :reason, :string, null: false
      add :source, :string, null: false, default: "manual"
      add :note, :text
      add :metadata, :map, null: false, default: %{}
      add :last_event_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime

      timestamps()
    end

    create index(:email_suppressions, [:user_id])
    create index(:email_suppressions, [:email])
    create index(:email_suppressions, [:expires_at])
    create unique_index(:email_suppressions, [:user_id, :email])
  end
end
