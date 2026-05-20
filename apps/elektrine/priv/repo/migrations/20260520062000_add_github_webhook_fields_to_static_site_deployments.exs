defmodule Elektrine.Repo.Migrations.AddGithubWebhookFieldsToStaticSiteDeployments do
  use Ecto.Migration

  def change do
    alter table(:static_site_deployments) do
      add :webhook_secret, :string
      add :webhook_id, :string
      add :deploy_status, :string, null: false, default: "idle"
      add :last_deploy_error, :text
    end

    execute(
      "UPDATE static_site_deployments SET webhook_secret = md5(random()::text || clock_timestamp()::text) WHERE webhook_secret IS NULL",
      ""
    )

    alter table(:static_site_deployments) do
      modify :webhook_secret, :string, null: false
    end
  end
end
