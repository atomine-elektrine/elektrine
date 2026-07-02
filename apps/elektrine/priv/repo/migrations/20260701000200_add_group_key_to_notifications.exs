defmodule Elektrine.Repo.Migrations.AddGroupKeyToNotifications do
  use Ecto.Migration

  def change do
    alter table(:notifications) do
      add :group_key, :text
    end

    create index(:notifications, [:user_id, :group_key, :inserted_at])
  end
end
