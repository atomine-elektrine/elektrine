defmodule Elektrine.Repo.Migrations.RemoveGithubFieldsFromUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove_if_exists :github_access_token, :string
      remove_if_exists :github_refresh_token, :string
      remove_if_exists :github_token_expires_at, :utc_datetime
      remove_if_exists :github_username, :string
    end
  end
end
