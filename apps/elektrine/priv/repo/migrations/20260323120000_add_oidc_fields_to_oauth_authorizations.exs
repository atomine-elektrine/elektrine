defmodule Elektrine.Repo.Migrations.AddOidcFieldsToOauthAuthorizations do
  use Ecto.Migration

  def change do
    alter table(:oauth_authorizations) do
      add :redirect_uri, :text
      add :state, :text
      add :nonce, :text
      add :code_challenge, :text
      add :code_challenge_method, :string
    end
  end
end
