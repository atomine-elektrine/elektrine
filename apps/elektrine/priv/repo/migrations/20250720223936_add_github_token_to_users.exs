defmodule Elektrine.Repo.Migrations.AddGithubTokenToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :github_access_token, :text
      add :github_refresh_token, :text
      add :github_token_expires_at, :utc_datetime
      add :github_username, :string
    end
  end
end
