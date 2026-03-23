defmodule Elektrine.Repo.Migrations.CreateOidcSigningKeys do
  use Ecto.Migration

  def change do
    create table(:oidc_signing_keys) do
      add :kid, :string, null: false
      add :alg, :string, null: false, default: "RS256"
      add :public_key_pem, :text, null: false
      add :private_key_pem, :text, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oidc_signing_keys, [:kid])
    create index(:oidc_signing_keys, [:active])
  end
end
