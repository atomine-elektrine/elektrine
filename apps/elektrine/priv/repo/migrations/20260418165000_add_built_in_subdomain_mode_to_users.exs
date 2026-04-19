defmodule Elektrine.Repo.Migrations.AddBuiltInSubdomainModeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :built_in_subdomain_mode, :string, null: false, default: "platform"
    end
  end
end
