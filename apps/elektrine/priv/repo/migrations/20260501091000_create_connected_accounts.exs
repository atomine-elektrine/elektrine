defmodule Elektrine.Repo.Migrations.CreateConnectedAccounts do
  use Ecto.Migration

  def change do
    create table(:connected_accounts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :provider_account_id, :string, null: false
      add :username, :string
      add :display_name, :string
      add :email, :string
      add :profile_url, :text
      add :avatar_url, :text
      add :scopes, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :last_verified_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:connected_accounts, [:provider, :provider_account_id])

    create unique_index(:connected_accounts, [:user_id, :provider, :provider_account_id],
             name: :connected_accounts_user_provider_account_unique
           )

    create index(:connected_accounts, [:user_id])
    create index(:connected_accounts, [:provider])
  end
end
