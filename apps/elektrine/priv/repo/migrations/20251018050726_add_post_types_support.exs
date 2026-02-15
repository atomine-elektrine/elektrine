defmodule Elektrine.Repo.Migrations.AddPostTypesSupport do
  use Ecto.Migration

  def change do
    # Add primary_url field for link posts
    alter table(:messages) do
      # Main URL for link-type posts
      add :primary_url, :text
    end

    create index(:messages, [:primary_url])

    # Create polls table for poll-type posts
    create table(:polls) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :question, :text, null: false
      # nil means never closes
      add :closes_at, :utc_datetime
      # Allow multiple selections
      add :allow_multiple, :boolean, default: false
      # Cached total for performance
      add :total_votes, :integer, default: 0

      timestamps()
    end

    create unique_index(:polls, [:message_id])

    # Create poll options
    create table(:poll_options) do
      add :poll_id, references(:polls, on_delete: :delete_all), null: false
      add :option_text, :string, null: false
      # Display order
      add :position, :integer, default: 0
      # Cached count for performance
      add :vote_count, :integer, default: 0

      timestamps()
    end

    create index(:poll_options, [:poll_id])

    # Create poll votes
    create table(:poll_votes) do
      add :poll_id, references(:polls, on_delete: :delete_all), null: false
      add :option_id, references(:poll_options, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    create unique_index(:poll_votes, [:poll_id, :user_id, :option_id])
    create index(:poll_votes, [:poll_id])
    create index(:poll_votes, [:user_id])
    create index(:poll_votes, [:option_id])

    # Update post_type constraint to include new types
    execute(
      "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_post_type_check",
      "ALTER TABLE messages ADD CONSTRAINT messages_post_type_check CHECK (post_type IN ('message', 'post', 'comment', 'share', 'discussion'))"
    )

    execute(
      "ALTER TABLE messages ADD CONSTRAINT messages_post_type_check CHECK (post_type IN ('message', 'post', 'comment', 'share', 'discussion', 'link', 'poll'))",
      "ALTER TABLE messages DROP CONSTRAINT messages_post_type_check"
    )
  end
end
