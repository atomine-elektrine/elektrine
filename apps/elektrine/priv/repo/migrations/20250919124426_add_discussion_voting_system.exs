defmodule Elektrine.Repo.Migrations.AddDiscussionVotingSystem do
  use Ecto.Migration

  def change do
    # Add voting fields to messages for discussion posts
    alter table(:messages) do
      add :upvotes, :integer, default: 0
      add :downvotes, :integer, default: 0
      # upvotes - downvotes
      add :score, :integer, default: 0
    end

    # Create message votes table for tracking individual votes
    create table(:message_votes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      # "up" or "down"
      add :vote_type, :string, null: false

      timestamps(updated_at: false)
    end

    # Add indexes for performance
    create unique_index(:message_votes, [:user_id, :message_id])
    create index(:message_votes, [:message_id])
    create index(:message_votes, [:vote_type])
    create index(:messages, [:score])
    create index(:messages, [:upvotes])
  end
end
