defmodule Elektrine.Repo.Migrations.RestoreExistingPlatformProfileSubdomains do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE users
    SET built_in_subdomain_mode = 'platform'
    WHERE built_in_subdomain_mode = 'path'
      AND inserted_at < TIMESTAMP '2026-06-01 00:01:00'
    """)
  end

  def down do
    :ok
  end
end
