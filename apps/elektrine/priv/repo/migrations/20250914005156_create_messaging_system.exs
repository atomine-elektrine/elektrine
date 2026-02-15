defmodule Elektrine.Repo.Migrations.CreateMessagingSystem do
  use Ecto.Migration

  def change do
    # Conversations table - supports DMs, group chats, and channels
    create table(:conversations) do
      # null for DMs, set for groups/channels
      add :name, :string
      # for groups/channels
      add :description, :text
      # "dm", "group", "channel"
      add :type, :string, null: false
      add :creator_id, references(:users, on_delete: :nilify_all)
      # for groups/channels
      add :avatar_url, :string
      # for channels
      add :is_public, :boolean, default: false
      add :member_count, :integer, default: 0
      add :last_message_at, :utc_datetime
      add :archived, :boolean, default: false

      timestamps()
    end

    # Conversation participants/members
    create table(:conversation_members) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # "admin", "member", "readonly" (for channels)
      add :role, :string, default: "member"
      add :joined_at, :utc_datetime, default: fragment("now()")
      # null if still member
      add :left_at, :utc_datetime
      add :last_read_at, :utc_datetime
      add :notifications_enabled, :boolean, default: true
      add :pinned, :boolean, default: false

      timestamps()
    end

    # Messages table
    create table(:messages) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :sender_id, references(:users, on_delete: :nilify_all), null: false
      add :content, :text
      # "text", "image", "file", "system"
      add :message_type, :string, default: "text"
      add :media_urls, {:array, :string}, default: []
      add :reply_to_id, references(:messages, on_delete: :nilify_all)
      add :edited_at, :utc_datetime
      add :deleted_at, :utc_datetime

      timestamps()
    end

    # Message reactions
    create table(:message_reactions) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :emoji, :string, null: false

      timestamps()
    end

    # Indexes for performance
    create index(:conversations, [:type])
    create index(:conversations, [:creator_id])
    create index(:conversations, [:last_message_at])
    # for public channels
    create index(:conversations, [:is_public])

    create unique_index(:conversation_members, [:conversation_id, :user_id])
    create index(:conversation_members, [:user_id])
    create index(:conversation_members, [:conversation_id, :left_at])

    create index(:messages, [:conversation_id])
    create index(:messages, [:sender_id])
    create index(:messages, [:inserted_at])
    create index(:messages, [:reply_to_id])
    create index(:messages, [:conversation_id, :inserted_at])

    create unique_index(:message_reactions, [:message_id, :user_id, :emoji])
    create index(:message_reactions, [:message_id])
  end
end
