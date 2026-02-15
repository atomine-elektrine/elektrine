defmodule Elektrine.Repo.Migrations.AddMrfPoliciesToInstances do
  use Ecto.Migration

  def change do
    alter table(:activitypub_instances) do
      # MRF policy flags - each represents a different level of restriction
      # More granular than just blocked/silenced
      add :media_removal, :boolean, default: false
      add :media_nsfw, :boolean, default: false
      add :federated_timeline_removal, :boolean, default: false
      add :followers_only, :boolean, default: false
      add :report_removal, :boolean, default: false
      add :avatar_removal, :boolean, default: false
      add :banner_removal, :boolean, default: false
      add :reject_deletes, :boolean, default: false

      # Track who applied each policy and when
      add :policy_applied_at, :utc_datetime
      add :policy_applied_by_id, references(:users, on_delete: :nilify_all)

      # Notes field for additional context
      add :notes, :text
    end

    # Create index for quick policy lookups (if_not_exists to handle pre-existing indices)
    create_if_not_exists index(:activitypub_instances, [:blocked])
    create_if_not_exists index(:activitypub_instances, [:silenced])
    create_if_not_exists index(:activitypub_instances, [:federated_timeline_removal])
  end
end
