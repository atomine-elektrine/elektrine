defmodule Elektrine.Repo.Migrations.AddCompositePerformanceIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # These indexes are created CONCURRENTLY to avoid locking the tables
    # during migration on production databases

    # Index for user profile timeline queries (sender_id + visibility + deleted_at + inserted_at)
    # Used in: get_user_timeline_posts(), profile pages
    create_if_not_exists index(:messages, [:sender_id, :visibility, :deleted_at, :inserted_at],
                           name: :messages_sender_visibility_deleted_inserted_idx,
                           concurrently: true
                         )

    # Index for conversation queries with visibility filtering
    # Used in: communities index, discussions, conversation views
    create_if_not_exists index(
                           :messages,
                           [:conversation_id, :visibility, :deleted_at, :inserted_at],
                           name: :messages_conv_visibility_deleted_inserted_idx,
                           concurrently: true
                         )

    # Index for public timeline and hashtag queries
    # Used in: hashtag pages, public timeline, federated timeline
    create_if_not_exists index(:messages, [:visibility, :deleted_at, :inserted_at],
                           name: :messages_visibility_deleted_inserted_idx,
                           concurrently: true
                         )

    # Index for approval status filtering (moderated communities)
    # Used in: queries that filter by approval_status
    create_if_not_exists index(:messages, [:approval_status, :visibility, :inserted_at],
                           name: :messages_approval_visibility_inserted_idx,
                           concurrently: true
                         )

    # Index for remote_actor_id queries (federated content)
    # Used in: federated timeline, remote actor posts
    create_if_not_exists index(
                           :messages,
                           [:remote_actor_id, :visibility, :deleted_at, :inserted_at],
                           name: :messages_remote_actor_visibility_deleted_inserted_idx,
                           concurrently: true,
                           where: "remote_actor_id IS NOT NULL"
                         )

    # Index for hashtag lookups by normalized name
    # Used in: hashtag pages, hashtag search
    create_if_not_exists index(:hashtags, [:normalized_name],
                           name: :hashtags_normalized_name_idx,
                           concurrently: true
                         )

    # Index for post_hashtags join table
    # Used in: hashtag post queries
    create_if_not_exists index(:post_hashtags, [:hashtag_id, :message_id],
                           name: :post_hashtags_hashtag_message_idx,
                           concurrently: true
                         )
  end
end
