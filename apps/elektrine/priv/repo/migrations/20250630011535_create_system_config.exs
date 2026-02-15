defmodule Elektrine.Repo.Migrations.CreateSystemConfig do
  use Ecto.Migration

  def change do
    create table(:system_config) do
      add :key, :string, null: false
      add :value, :text
      add :type, :string, default: "string"
      add :description, :text

      timestamps()
    end

    create unique_index(:system_config, [:key])

    # Insert default configuration
    execute """
            INSERT INTO system_config (key, value, type, description, inserted_at, updated_at)
            VALUES ('invite_codes_enabled', 'true', 'boolean', 'Enable or disable the invite code system for user registration', NOW(), NOW())
            """,
            ""
  end
end
