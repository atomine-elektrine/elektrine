defmodule Elektrine.Repo.Migrations.AddProfileEditingDeployLinkImageFeatures do
  use Ecto.Migration

  def change do
    alter table(:static_site_deployments) do
      add :last_commit_sha, :string
      add :last_commit_url, :text
      add :last_commit_message, :text
      add :last_deploy_log, :text
    end

    create table(:static_site_deploys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :deployment_id, references(:static_site_deployments, on_delete: :delete_all),
        null: false

      add :status, :string, null: false
      add :trigger, :string, null: false, default: "manual"
      add :repo_owner, :string
      add :repo_name, :string
      add :branch, :string
      add :site_dir, :string
      add :commit_sha, :string
      add :commit_url, :text
      add :commit_message, :text
      add :log, :text
      add :error, :text
      add :snapshot_storage_key, :text
      add :file_count, :integer, null: false, default: 0
      add :storage_bytes, :bigint, null: false, default: 0
      add :deployed_at, :utc_datetime

      timestamps()
    end

    create index(:static_site_deploys, [:deployment_id, :deployed_at])
    create index(:static_site_deploys, [:user_id, :deployed_at])

    alter table(:profile_links) do
      add :pinned, :boolean, null: false, default: false
      add :active_from, :utc_datetime
      add :active_until, :utc_datetime
      add :impressions, :integer, null: false, default: 0
      add :last_clicked_at, :utc_datetime
      add :last_checked_at, :utc_datetime
      add :last_check_status, :string
      add :last_check_error, :text
    end

    create index(:profile_links, [:profile_id, :pinned])
    create index(:profile_links, [:profile_id, :active_from])
    create index(:profile_links, [:profile_id, :active_until])

    alter table(:user_profiles) do
      add :avatar_alt_text, :string
      add :banner_alt_text, :string
      add :background_alt_text, :string
      add :avatar_focal_x, :float, null: false, default: 50.0
      add :avatar_focal_y, :float, null: false, default: 50.0
      add :background_focal_x, :float, null: false, default: 50.0
      add :background_focal_y, :float, null: false, default: 50.0
      add :background_brightness, :integer, null: false, default: 100
      add :background_overlay_blur, :integer, null: false, default: 0
    end
  end
end
