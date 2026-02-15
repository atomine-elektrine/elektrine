defmodule Elektrine.Repo.Migrations.AddMissingPerformanceIndexes do
  use Ecto.Migration

  def change do
    # Composite index for user timeline queries (get_user_timeline_posts)
    # Filters: sender_id, post_type, visibility, deleted_at, order by inserted_at
    create_if_not_exists index(
                           :messages,
                           [:sender_id, :post_type, :visibility, :deleted_at, :inserted_at],
                           name: :messages_user_timeline_idx,
                           where: "post_type = 'post' AND deleted_at IS NULL"
                         )

    # Composite index for conversation message queries with better ordering
    # Many queries filter by conversation_id and order by inserted_at
    create_if_not_exists index(:messages, [:conversation_id, :inserted_at, :deleted_at],
                           name: :messages_conversation_timeline_idx,
                           where: "deleted_at IS NULL"
                         )

    # Only create these indexes if the tables exist (they're from a later migration)
    if table_exists?(:user_follows) do
      create_if_not_exists index(:user_follows, [:followed_id, :follower_id],
                             name: :user_follows_reverse_idx
                           )
    end

    if table_exists?(:post_likes) do
      create_if_not_exists index(:post_likes, [:message_id, :created_at],
                             name: :post_likes_by_message_idx
                           )
    end
  end

  defp table_exists?(table_name) when table_name in [:user_follows, :post_likes] do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_name = $1
    )
    """

    result = Ecto.Adapters.SQL.query!(Elektrine.Repo, query, [Atom.to_string(table_name)])
    [[exists]] = result.rows
    exists
  end
end
