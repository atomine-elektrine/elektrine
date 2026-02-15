defmodule Elektrine.Repo.Migrations.AddVerifiedToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :verified, :boolean, default: false
    end
  end
end
