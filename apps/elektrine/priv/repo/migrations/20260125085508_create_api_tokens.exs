defmodule Elektrine.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :token_prefix, :string, null: false
      add :scopes, {:array, :string}, default: [], null: false
      add :last_used_at, :utc_datetime
      add :last_used_ip, :string
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])
    create index(:api_tokens, [:user_id, :revoked_at])
  end
end
