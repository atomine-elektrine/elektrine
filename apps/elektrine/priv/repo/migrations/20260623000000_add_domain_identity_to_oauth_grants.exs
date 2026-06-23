defmodule Elektrine.Repo.Migrations.AddDomainIdentityToOAuthGrants do
  use Ecto.Migration

  def change do
    alter table(:oauth_authorizations) do
      add :identity_subject, :string
      add :identity_domain, :string
      add :identity_did, :string
    end

    alter table(:oauth_tokens) do
      add :identity_subject, :string
      add :identity_domain, :string
      add :identity_did, :string
    end

    create index(:oauth_authorizations, [:identity_subject])
    create index(:oauth_tokens, [:identity_subject])
  end
end
