defmodule Elektrine.Repo.Migrations.AddTrustLevelSystem do
  use Ecto.Migration

  def change do
    # Add trust level to users table
    alter table(:users) do
      add :trust_level, :integer, default: 0, null: false
      # Prevent auto-promotion if manually set
      add :trust_level_locked, :boolean, default: false
      # When they reached current level
      add :promoted_at, :utc_datetime
    end

    # User activity stats for trust level calculation
    create table(:user_activity_stats) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # Content creation
      add :posts_created, :integer, default: 0
      add :topics_created, :integer, default: 0
      add :replies_created, :integer, default: 0

      # Engagement metrics
      add :likes_given, :integer, default: 0
      add :likes_received, :integer, default: 0
      add :replies_received, :integer, default: 0

      # Reading metrics
      add :posts_read, :integer, default: 0
      add :topics_entered, :integer, default: 0
      add :time_read_seconds, :integer, default: 0

      # Visit tracking
      add :days_visited, :integer, default: 0
      add :last_visit_date, :date

      # Moderation
      add :flags_given, :integer, default: 0
      add :flags_received, :integer, default: 0
      # When your flags were valid
      add :flags_agreed, :integer, default: 0

      # Penalties
      add :posts_deleted, :integer, default: 0
      add :suspensions_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_activity_stats, [:user_id])

    # Trust level change log
    create table(:trust_level_logs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :old_level, :integer, null: false
      add :new_level, :integer, null: false
      # "automatic", "manual", "penalty"
      add :reason, :string
      # If manually changed
      add :changed_by_user_id, references(:users, on_delete: :nilify_all)
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:trust_level_logs, [:user_id])
    create index(:trust_level_logs, [:inserted_at])
  end
end
