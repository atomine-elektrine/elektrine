defmodule Elektrine.Repo.Migrations.CreateMessagingServers do
  use Ecto.Migration

  def change do
    create table(:messaging_servers) do
      add :name, :string, null: false
      add :description, :text
      add :icon_url, :string
      add :is_public, :boolean, default: false, null: false
      add :member_count, :integer, default: 0, null: false
      add :last_activity_at, :utc_datetime
      add :creator_id, references(:users, on_delete: :nilify_all)

      timestamps()
    end

    create index(:messaging_servers, [:creator_id])
    create index(:messaging_servers, [:is_public])
    create index(:messaging_servers, [:member_count])

    create table(:messaging_server_members) do
      add :server_id, references(:messaging_servers, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, default: "member", null: false
      add :joined_at, :utc_datetime, default: fragment("now()")
      add :left_at, :utc_datetime
      add :notifications_enabled, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:messaging_server_members, [:server_id, :user_id])
    create index(:messaging_server_members, [:user_id])
    create index(:messaging_server_members, [:server_id, :left_at])

    alter table(:conversations) do
      add :server_id, references(:messaging_servers, on_delete: :delete_all)
      add :channel_topic, :text
      add :channel_position, :integer, default: 0, null: false
    end

    create index(:conversations, [:server_id])
    create index(:conversations, [:server_id, :channel_position])
  end
end
