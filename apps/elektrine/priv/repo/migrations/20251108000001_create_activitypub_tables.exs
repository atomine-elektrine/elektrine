defmodule Elektrine.Repo.Migrations.CreateActivitypubTables do
  use Ecto.Migration

  def change do
    # Remote actors (users from other instances)
    create table(:activitypub_actors) do
      # Full ActivityPub ID (e.g., https://mastodon.social/users/alice)
      add :uri, :string, null: false
      # Local username part
      add :username, :string, null: false
      # Remote domain (e.g., mastodon.social)
      add :domain, :string, null: false
      add :display_name, :string
      # Bio
      add :summary, :text
      add :avatar_url, :string
      add :header_url, :string
      add :inbox_url, :string, null: false
      add :outbox_url, :string
      add :followers_url, :string
      add :following_url, :string
      add :public_key, :text, null: false
      add :manually_approves_followers, :boolean, default: false
      # Person, Service, Group, etc.
      add :actor_type, :string, default: "Person"
      add :last_fetched_at, :utc_datetime
      # Store additional fields
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:activitypub_actors, [:uri])
    create index(:activitypub_actors, [:domain])
    create index(:activitypub_actors, [:username, :domain])

    # Activities (incoming and outgoing)
    create table(:activitypub_activities) do
      # Full ActivityPub ID
      add :activity_id, :string, null: false
      # Create, Follow, Like, Announce, etc.
      add :activity_type, :string, null: false
      add :actor_uri, :string, null: false
      # The object being acted upon
      add :object_id, :string
      # Full JSON-LD activity
      add :data, :map, null: false
      # Created locally vs received
      add :local, :boolean, default: false
      # For local activities
      add :internal_user_id, references(:users, on_delete: :delete_all)
      # Link to local message
      add :internal_message_id, references(:messages, on_delete: :delete_all)

      timestamps()
    end

    create unique_index(:activitypub_activities, [:activity_id])
    create index(:activitypub_activities, [:activity_type])
    create index(:activitypub_activities, [:actor_uri])
    create index(:activitypub_activities, [:object_id])
    create index(:activitypub_activities, [:internal_user_id])
    create index(:activitypub_activities, [:internal_message_id])
    create index(:activitypub_activities, [:local])

    # Activity deliveries (track outgoing activity delivery status)
    create table(:activitypub_deliveries) do
      add :activity_id, references(:activitypub_activities, on_delete: :delete_all), null: false
      add :inbox_url, :string, null: false
      # pending, delivered, failed
      add :status, :string, default: "pending"
      add :attempts, :integer, default: 0
      add :last_attempt_at, :utc_datetime
      add :next_retry_at, :utc_datetime
      add :error_message, :text

      timestamps()
    end

    create index(:activitypub_deliveries, [:activity_id])
    create index(:activitypub_deliveries, [:status])
    create index(:activitypub_deliveries, [:next_retry_at])

    # Instance blocks/allows for moderation
    create table(:activitypub_instances) do
      add :domain, :string, null: false
      add :blocked, :boolean, default: false
      # Allow but don't show in public timelines
      add :silenced, :boolean, default: false
      add :reason, :text
      add :blocked_by_id, references(:users, on_delete: :nilify_all)
      add :blocked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:activitypub_instances, [:domain])
    create index(:activitypub_instances, [:blocked])

    # User-level instance/user blocks
    create table(:activitypub_user_blocks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Can be an actor URI or domain
      add :blocked_uri, :string, null: false
      # user or domain
      add :block_type, :string, default: "user"

      timestamps()
    end

    create index(:activitypub_user_blocks, [:user_id])
    create index(:activitypub_user_blocks, [:blocked_uri])
    create unique_index(:activitypub_user_blocks, [:user_id, :blocked_uri])

    # Add ActivityPub fields to users table
    alter table(:users) do
      add :activitypub_enabled, :boolean, default: true
      # RSA private key for HTTP signatures
      add :activitypub_private_key, :text
      # RSA public key
      add :activitypub_public_key, :text
      add :activitypub_manually_approve_followers, :boolean, default: false
    end

    # Add ActivityPub fields to messages table for tracking federated content
    alter table(:messages) do
      # Full ActivityPub ID for this message
      add :activitypub_id, :string
      # Public URL for this message
      add :activitypub_url, :string
      # Whether this came from federation
      add :federated, :boolean, default: false
      # If from remote user
      add :remote_actor_id, references(:activitypub_actors, on_delete: :nilify_all)
    end

    create unique_index(:messages, [:activitypub_id], where: "activitypub_id IS NOT NULL")
    create index(:messages, [:remote_actor_id])
    create index(:messages, [:federated])

    # Add ActivityPub tracking to follows
    alter table(:follows) do
      # ActivityPub Follow activity ID
      add :activitypub_id, :string
      # If following/followed by remote user
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all)
      # For follow requests that need approval
      add :pending, :boolean, default: false
    end

    create index(:follows, [:remote_actor_id])
    create index(:follows, [:pending])
  end
end
