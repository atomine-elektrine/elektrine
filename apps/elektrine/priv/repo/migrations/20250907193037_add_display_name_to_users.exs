defmodule Elektrine.Repo.Migrations.AddDisplayNameToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :display_name, :string, size: 100
    end
  end
end
