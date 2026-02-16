defmodule Elektrine.Repo.Migrations.RemoveCustomDomains do
  use Ecto.Migration

  def up do
    drop_if_exists(table(:custom_domain_addresses))
    drop_if_exists(table(:custom_domains))
  end

  def down do
    raise "Custom domain support was removed and this migration is irreversible"
  end
end
