defmodule Elektrine.Repo.Migrations.EnhanceRecommendationTracking do
  use Ecto.Migration

  def change do
    # Enhance post_views with dwell time tracking
    alter table(:post_views) do
      # milliseconds spent on post
      add :dwell_time_ms, :integer
      # 0.0-1.0 how much of post was visible
      add :scroll_depth, :float
      # clicked to expand/read more
      add :expanded, :boolean, default: false
      # where they saw the post (feed, profile, search, etc.)
      add :source, :string
    end

    # Create post_dismissals for negative signals
    create table(:post_dismissals) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      # scrolled_past, hidden, not_interested
      add :dismissal_type, :string, null: false
      # how long before dismissing
      add :dwell_time_ms, :integer

      timestamps(updated_at: false)
    end

    create index(:post_dismissals, [:user_id])
    create index(:post_dismissals, [:message_id])
    create index(:post_dismissals, [:user_id, :dismissal_type])
    create unique_index(:post_dismissals, [:user_id, :message_id, :dismissal_type])

    # Create creator_satisfaction for tracking satisfaction signals
    create table(:creator_satisfaction) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :creator_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all)
      add :followed_after_viewing, :boolean, default: false
      # kept viewing their content
      add :continued_engagement, :boolean, default: false
      # regret signal
      add :immediate_leave, :boolean, default: false
      add :total_posts_viewed, :integer, default: 0
      add :total_dwell_time_ms, :integer, default: 0

      timestamps()
    end

    create unique_index(:creator_satisfaction, [:user_id, :creator_id],
             where: "creator_id IS NOT NULL AND remote_actor_id IS NULL"
           )

    create unique_index(:creator_satisfaction, [:user_id, :remote_actor_id],
             where: "remote_actor_id IS NOT NULL"
           )

    create index(:creator_satisfaction, [:creator_id])
    create index(:creator_satisfaction, [:remote_actor_id])

    # Add index for efficient dwell time queries
    create index(:post_views, [:user_id, :dwell_time_ms])
  end
end
