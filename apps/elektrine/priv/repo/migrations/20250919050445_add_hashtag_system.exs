defmodule Elektrine.Repo.Migrations.AddHashtagSystem do
  use Ecto.Migration

  def change do
    # Create hashtags table
    create table(:hashtags) do
      add :name, :string, null: false
      # lowercase for consistent lookup
      add :normalized_name, :string, null: false
      add :use_count, :integer, default: 0
      add :last_used_at, :utc_datetime

      timestamps()
    end

    # Create post_hashtags join table
    create table(:post_hashtags) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :hashtag_id, references(:hashtags, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    # Add hashtag fields to messages
    alter table(:messages) do
      add :extracted_hashtags, {:array, :string}, default: []
    end

    # Add indexes for performance
    create unique_index(:hashtags, [:normalized_name])
    create index(:hashtags, [:use_count])
    create index(:hashtags, [:last_used_at])
    create unique_index(:post_hashtags, [:message_id, :hashtag_id])
    create index(:post_hashtags, [:hashtag_id])
    create index(:messages, [:extracted_hashtags])
  end
end
