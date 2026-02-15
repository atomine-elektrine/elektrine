defmodule Elektrine.Repo.Migrations.AddCommunityFlairs do
  use Ecto.Migration

  def change do
    # Create community flairs table
    create table(:community_flairs) do
      add :name, :string, null: false
      add :text_color, :string, default: "#FFFFFF"
      add :background_color, :string, default: "#4B5563"
      add :community_id, references(:conversations, on_delete: :delete_all), null: false
      add :position, :integer, default: 0
      add :is_mod_only, :boolean, default: false
      add :is_enabled, :boolean, default: true

      timestamps()
    end

    create index(:community_flairs, [:community_id])
    create unique_index(:community_flairs, [:community_id, :name])

    # Add flair_id to messages table for posts in communities
    alter table(:messages) do
      add :flair_id, references(:community_flairs, on_delete: :nilify_all)
    end

    create index(:messages, [:flair_id])
  end
end
