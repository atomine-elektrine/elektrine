defmodule Elektrine.Repo.Migrations.AddDkimFieldsToEmailCustomDomains do
  use Ecto.Migration

  def change do
    alter table(:email_custom_domains) do
      add :dkim_selector, :string
      add :dkim_public_key, :text
      add :dkim_private_key, :text
      add :dkim_synced_at, :utc_datetime
      add :dkim_last_error, :string
    end
  end
end
