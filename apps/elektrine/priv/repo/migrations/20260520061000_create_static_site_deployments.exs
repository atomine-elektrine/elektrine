defmodule Elektrine.Repo.Migrations.CreateStaticSiteDeployments do
  use Ecto.Migration

  def change do
    create table(:static_site_deployments) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false, default: "github"
      add :repo_owner, :string, null: false
      add :repo_name, :string, null: false
      add :branch, :string, null: false, default: "main"
      add :site_dir, :string, null: false, default: "auto"
      add :build_command, :text
      add :last_deployed_at, :utc_datetime

      timestamps()
    end

    create index(:static_site_deployments, [:user_id])
    create unique_index(:static_site_deployments, [:provider, :repo_owner, :repo_name])
  end
end
