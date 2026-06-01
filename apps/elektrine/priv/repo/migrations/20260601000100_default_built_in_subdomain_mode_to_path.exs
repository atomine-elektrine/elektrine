defmodule Elektrine.Repo.Migrations.DefaultBuiltInSubdomainModeToPath do
  use Ecto.Migration

  def up do
    execute(
      "UPDATE users SET built_in_subdomain_mode = 'path' WHERE built_in_subdomain_mode = 'platform'"
    )

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
