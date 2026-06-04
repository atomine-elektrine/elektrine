defmodule Elektrine.Repo.Migrations.DefaultBuiltInSubdomainModeToPath do
  use Ecto.Migration

  def up do
    alter table(:users) do
      modify :built_in_subdomain_mode, :string, null: false, default: "path"
    end
  end

  def down do
    alter table(:users) do
      modify :built_in_subdomain_mode, :string, null: false, default: "platform"
    end
  end
end
