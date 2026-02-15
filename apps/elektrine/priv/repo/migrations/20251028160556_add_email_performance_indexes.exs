defmodule Elektrine.Repo.Migrations.AddEmailPerformanceIndexes do
  use Ecto.Migration

  def change do
    # Composite indexes for common email queries to improve performance
    # These support the most frequent query patterns in digest, ledger, stack, and boomerang views

    # Index for Feed (digest) queries: mailbox_id + category + flags + inserted_at
    create_if_not_exists index(
                           :email_messages,
                           [:mailbox_id, :category, :spam, :archived, :deleted, :inserted_at],
                           where:
                             "category = 'feed' AND NOT spam AND NOT archived AND NOT deleted",
                           name: :email_messages_feed_performance_idx
                         )

    # Index for Ledger queries: mailbox_id + category + flags + inserted_at
    create_if_not_exists index(
                           :email_messages,
                           [:mailbox_id, :category, :spam, :archived, :deleted, :inserted_at],
                           where:
                             "category = 'ledger' AND NOT spam AND NOT archived AND NOT deleted",
                           name: :email_messages_ledger_performance_idx
                         )

    # Index for Stack queries: mailbox_id + category + stack_at + flags
    create_if_not_exists index(
                           :email_messages,
                           [:mailbox_id, :category, :stack_at, :spam, :archived, :deleted],
                           where:
                             "category = 'stack' AND stack_at IS NOT NULL AND NOT spam AND NOT archived AND NOT deleted",
                           name: :email_messages_stack_performance_idx
                         )

    # Index for Boomerang (reply_later) queries: mailbox_id + reply_later_at + flags
    create_if_not_exists index(
                           :email_messages,
                           [:mailbox_id, :reply_later_at, :spam, :archived, :deleted],
                           where:
                             "reply_later_at IS NOT NULL AND NOT spam AND NOT archived AND NOT deleted",
                           name: :email_messages_boomerang_performance_idx
                         )

    # Index for unread messages: mailbox_id + read + flags + inserted_at
    create_if_not_exists index(
                           :email_messages,
                           [:mailbox_id, :read, :spam, :archived, :deleted, :inserted_at],
                           where: "NOT read AND NOT spam AND NOT archived AND NOT deleted",
                           name: :email_messages_unread_performance_idx
                         )

    # Index for read messages: mailbox_id + read + flags + inserted_at
    create_if_not_exists index(
                           :email_messages,
                           [:mailbox_id, :read, :spam, :archived, :deleted, :inserted_at],
                           where: "read AND NOT spam AND NOT archived AND NOT deleted",
                           name: :email_messages_read_performance_idx
                         )

    # Index for inbox queries (complex filter): mailbox_id + multiple conditions
    create_if_not_exists index(
                           :email_messages,
                           [
                             :mailbox_id,
                             :category,
                             :spam,
                             :archived,
                             :deleted,
                             :reply_later_at,
                             :inserted_at
                           ],
                           where:
                             "NOT spam AND NOT archived AND NOT deleted AND category NOT IN ('feed', 'ledger', 'stack') AND reply_later_at IS NULL",
                           name: :email_messages_inbox_performance_idx
                         )
  end
end
