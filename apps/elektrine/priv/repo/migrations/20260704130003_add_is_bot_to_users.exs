defmodule Elektrine.Repo.Migrations.AddIsBotToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_bot, :boolean, default: false, null: false
    end
  end
end
