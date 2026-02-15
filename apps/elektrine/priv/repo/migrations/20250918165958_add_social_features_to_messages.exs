defmodule Elektrine.Repo.Migrations.AddSocialFeaturesToMessages do
  use Ecto.Migration

  def change do
    # Extend messages table for timeline posts and social features
    alter table(:messages) do
      add :visibility, :string, default: "conversation"
      add :post_type, :string, default: "message"
      add :like_count, :integer, default: 0
      add :reply_count, :integer, default: 0
      add :share_count, :integer, default: 0
    end

    # Extend conversations table for community features
    alter table(:conversations) do
      add :space_type, :string, default: "chat"
      add :community_category, :string
      add :allow_public_posts, :boolean, default: false
      add :discussion_style, :string, default: "chat"
    end

    # Create user follows table
    create table(:user_follows) do
      add :follower_id, references(:users, on_delete: :delete_all), null: false
      add :followed_id, references(:users, on_delete: :delete_all), null: false
      add :created_at, :utc_datetime, default: fragment("NOW()"), null: false
    end

    # Create post likes table
    create table(:post_likes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :created_at, :utc_datetime, default: fragment("NOW()"), null: false
    end

    # Add indexes for performance
    create unique_index(:user_follows, [:follower_id, :followed_id])
    create unique_index(:post_likes, [:user_id, :message_id])
    create index(:messages, [:visibility])
    create index(:messages, [:post_type])
    create index(:messages, [:like_count])
    create index(:conversations, [:space_type])
    create index(:conversations, [:community_category])
  end
end
