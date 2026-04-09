defmodule Elektrine.Repo.Migrations.SplitChatConversationsFromSocialSpaces do
  use Ecto.Migration

  def up do
    create table(:chat_conversations) do
      add :name, :string
      add :description, :text
      add :type, :string, null: false
      add :creator_id, references(:users, on_delete: :nilify_all)
      add :avatar_url, :string
      add :is_public, :boolean, default: false
      add :member_count, :integer, default: 0
      add :last_message_at, :utc_datetime
      add :archived, :boolean, default: false
      add :hash, :string
      add :slow_mode_seconds, :integer, default: 0
      add :approval_mode_enabled, :boolean, default: false
      add :approval_threshold_posts, :integer, default: 3
      add :channel_topic, :string
      add :channel_position, :integer, default: 0
      add :server_id, references(:messaging_servers, on_delete: :delete_all)
      add :federated_source, :string
      add :is_federated_mirror, :boolean, default: false
      add :remote_group_actor_id, references(:activitypub_actors, on_delete: :nilify_all)

      timestamps()
    end

    create index(:chat_conversations, [:type])
    create index(:chat_conversations, [:creator_id])
    create index(:chat_conversations, [:last_message_at])
    create index(:chat_conversations, [:is_public])
    create index(:chat_conversations, [:server_id])
    create unique_index(:chat_conversations, [:hash])

    create table(:chat_conversation_members) do
      add :conversation_id, references(:chat_conversations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, default: "member"
      add :joined_at, :utc_datetime, default: fragment("now()")
      add :left_at, :utc_datetime
      add :last_read_at, :utc_datetime
      add :last_read_message_id, references(:chat_messages, on_delete: :nilify_all)
      add :notifications_enabled, :boolean, default: true
      add :pinned, :boolean, default: false

      timestamps()
    end

    create unique_index(:chat_conversation_members, [:conversation_id, :user_id])
    create index(:chat_conversation_members, [:user_id])
    create index(:chat_conversation_members, [:conversation_id, :left_at])
    create index(:chat_conversation_members, [:last_read_message_id])

    execute("""
    INSERT INTO chat_conversations (
      id,
      name,
      description,
      type,
      creator_id,
      avatar_url,
      is_public,
      member_count,
      last_message_at,
      archived,
      hash,
      slow_mode_seconds,
      approval_mode_enabled,
      approval_threshold_posts,
      channel_topic,
      channel_position,
      server_id,
      federated_source,
      is_federated_mirror,
      remote_group_actor_id,
      inserted_at,
      updated_at
    )
    SELECT
      id,
      name,
      description,
      type,
      creator_id,
      avatar_url,
      is_public,
      member_count,
      last_message_at,
      archived,
      hash,
      slow_mode_seconds,
      approval_mode_enabled,
      approval_threshold_posts,
      channel_topic,
      channel_position,
      server_id,
      federated_source,
      is_federated_mirror,
      remote_group_actor_id,
      inserted_at,
      updated_at
    FROM conversations
    WHERE type IN ('dm', 'group', 'channel')
    """)

    execute("""
    INSERT INTO chat_conversation_members (
      conversation_id,
      user_id,
      role,
      joined_at,
      left_at,
      last_read_at,
      notifications_enabled,
      pinned,
      inserted_at,
      updated_at
    )
    SELECT
      cm.conversation_id,
      cm.user_id,
      cm.role,
      cm.joined_at,
      cm.left_at,
      cm.last_read_at,
      cm.notifications_enabled,
      cm.pinned,
      cm.inserted_at,
      cm.updated_at
    FROM conversation_members cm
    INNER JOIN conversations c ON c.id = cm.conversation_id
    WHERE c.type IN ('dm', 'group', 'channel')
    """)

    execute("""
    SELECT setval(
      pg_get_serial_sequence('chat_conversations', 'id'),
      COALESCE((SELECT MAX(id) FROM chat_conversations), 1),
      true
    )
    """)
  end

  def down do
    drop table(:chat_conversation_members)
    drop table(:chat_conversations)
  end
end
