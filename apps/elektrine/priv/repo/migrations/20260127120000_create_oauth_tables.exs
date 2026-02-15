defmodule Elektrine.Repo.Migrations.CreateOAuthTables do
  use Ecto.Migration

  def change do
    # OAuth Apps - Third-party application registrations
    create table(:oauth_apps) do
      add :client_name, :string, null: false
      add :redirect_uris, :text, null: false
      add :scopes, {:array, :string}, default: ["read"], null: false
      add :website, :string
      add :client_id, :string, null: false
      add :client_secret, :string, null: false
      add :trusted, :boolean, default: false, null: false
      add :user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_apps, [:client_id])
    create index(:oauth_apps, [:user_id])

    # OAuth Authorizations - Short-lived authorization codes
    create table(:oauth_authorizations) do
      add :token, :string, null: false
      add :scopes, {:array, :string}, default: [], null: false
      add :valid_until, :utc_datetime, null: false
      add :used, :boolean, default: false, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :app_id, references(:oauth_apps, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_authorizations, [:token])
    create index(:oauth_authorizations, [:app_id])
    create index(:oauth_authorizations, [:user_id])

    # OAuth Tokens - Long-lived access tokens
    create table(:oauth_tokens) do
      add :token, :string, null: false
      add :refresh_token, :string, null: false
      add :scopes, {:array, :string}, default: [], null: false
      add :valid_until, :utc_datetime, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :app_id, references(:oauth_apps, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_tokens, [:token])
    create unique_index(:oauth_tokens, [:refresh_token])
    create index(:oauth_tokens, [:app_id])
    create index(:oauth_tokens, [:user_id])
    create index(:oauth_tokens, [:valid_until])
  end
end
