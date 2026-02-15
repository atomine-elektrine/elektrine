defmodule Elektrine.Repo.Migrations.AddBannedToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :banned, :boolean, default: false, null: false
      add :banned_at, :utc_datetime
      add :banned_reason, :string
    end
  end
end
