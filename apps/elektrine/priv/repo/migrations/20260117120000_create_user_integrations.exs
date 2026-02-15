defmodule Elektrine.Repo.Migrations.CreateUserIntegrations do
  use Ecto.Migration

  def change do
    create table(:user_integrations) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :provider_user_id, :string
      add :username, :string
      add :avatar_url, :string
      add :access_token, :binary
      add :refresh_token, :binary
      add :token_expires_at, :utc_datetime
      add :scopes, {:array, :string}, default: []
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:user_integrations, [:user_id, :provider])
    create index(:user_integrations, [:provider])
  end
end
