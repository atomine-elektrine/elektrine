defmodule Elektrine.Repo.Migrations.AddOidcFieldsToOauthTokens do
  use Ecto.Migration

  def change do
    alter table(:oauth_tokens) do
      add :oidc_nonce, :text
      add :oidc_auth_time, :utc_datetime
    end
  end
end
