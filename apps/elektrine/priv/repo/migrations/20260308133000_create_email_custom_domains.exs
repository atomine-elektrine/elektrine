defmodule Elektrine.Repo.Migrations.CreateEmailCustomDomains do
  use Ecto.Migration

  def change do
    create table(:email_custom_domains) do
      add :domain, :string, null: false
      add :verification_token, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :verified_at, :utc_datetime
      add :last_checked_at, :utc_datetime
      add :last_error, :string
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:email_custom_domains, [:user_id])
    create index(:email_custom_domains, [:status])

    create unique_index(:email_custom_domains, ["lower(domain)"],
             name: :email_custom_domains_domain_ci_unique
           )
  end
end
