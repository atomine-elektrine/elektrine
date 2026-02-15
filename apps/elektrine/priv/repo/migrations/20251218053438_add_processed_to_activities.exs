defmodule Elektrine.Repo.Migrations.AddProcessedToActivities do
  use Ecto.Migration

  def change do
    alter table(:activitypub_activities) do
      add :processed, :boolean, default: false
      add :processed_at, :utc_datetime
      add :process_error, :string
      add :process_attempts, :integer, default: 0
    end

    # Index for finding unprocessed activities efficiently
    create index(:activitypub_activities, [:processed, :local],
             where: "processed = false AND local = false"
           )

    # Index for retry logic
    create index(:activitypub_activities, [:process_attempts],
             where: "processed = false AND process_attempts < 3"
           )
  end
end
