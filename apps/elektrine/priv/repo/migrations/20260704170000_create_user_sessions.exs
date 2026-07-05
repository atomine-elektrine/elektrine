defmodule Elektrine.Repo.Migrations.CreateUserSessions do
  use Ecto.Migration

  def change do
    create table(:user_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :auth_method, :string, null: false, default: "password"
      add :device_label, :string
      add :browser, :string
      add :platform, :string
      add :ip_address, :string
      add :user_agent, :text
      add :remembered, :boolean, null: false, default: false
      add :last_seen_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :revoked_reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:user_sessions, [:user_id, :revoked_at])
    create index(:user_sessions, [:user_id, :last_seen_at])
  end
end
