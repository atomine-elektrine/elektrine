defmodule Elektrine.Repo.Migrations.CreateCommunityBans do
  use Ecto.Migration

  def change do
    create table(:community_bans) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :banned_by_id, references(:users, on_delete: :nilify_all), null: false
      add :reason, :text
      add :expires_at, :utc_datetime

      timestamps()
    end

    create unique_index(:community_bans, [:conversation_id, :user_id])
    create index(:community_bans, [:user_id])
    create index(:community_bans, [:expires_at])
  end
end
