defmodule Elektrine.Repo.Migrations.RelaxDkimConstraintsOnEmailCustomDomains do
  use Ecto.Migration

  def change do
    alter table(:email_custom_domains) do
      modify :dkim_selector, :string, null: true, default: nil
      modify :dkim_public_key, :text, null: true
      modify :dkim_private_key, :text, null: true
    end
  end
end
