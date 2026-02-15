defmodule Elektrine.Repo.Migrations.AddVoteIndexes do
  use Ecto.Migration

  def change do
    # Add indexes for efficient vote queries
    create index(:message_votes, [:message_id, :vote_type])
    create index(:message_votes, [:user_id])
    create index(:message_votes, [:inserted_at])

    # Composite index for the most common query pattern
    create index(:message_votes, [:message_id, :vote_type, :inserted_at])
  end
end
