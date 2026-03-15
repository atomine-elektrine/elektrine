defmodule Elektrine.Repo.Migrations.NormalizePostViewsForTrustTracking do
  use Ecto.Migration

  def up do
    execute("""
    WITH duplicates AS (
      SELECT
        MIN(id) AS keep_id,
        user_id,
        message_id,
        MAX(view_duration_seconds) AS max_view_duration_seconds,
        BOOL_OR(COALESCE(completed, FALSE)) AS any_completed,
        SUM(COALESCE(dwell_time_ms, 0)) AS total_dwell_time_ms,
        MAX(COALESCE(scroll_depth, 0)) AS max_scroll_depth,
        BOOL_OR(COALESCE(expanded, FALSE)) AS any_expanded,
        MAX(source) FILTER (WHERE source IS NOT NULL AND btrim(source) <> '') AS chosen_source
      FROM post_views
      GROUP BY user_id, message_id
      HAVING COUNT(*) > 1
    )
    UPDATE post_views AS pv
    SET
      view_duration_seconds = duplicates.max_view_duration_seconds,
      completed = duplicates.any_completed,
      dwell_time_ms = CASE
        WHEN duplicates.total_dwell_time_ms > 0 THEN duplicates.total_dwell_time_ms
        ELSE pv.dwell_time_ms
      END,
      scroll_depth = CASE
        WHEN duplicates.max_scroll_depth > 0 THEN duplicates.max_scroll_depth
        ELSE pv.scroll_depth
      END,
      expanded = duplicates.any_expanded,
      source = COALESCE(duplicates.chosen_source, pv.source)
    FROM duplicates
    WHERE pv.id = duplicates.keep_id
    """)

    execute("""
    WITH duplicates AS (
      SELECT
        MIN(id) AS keep_id,
        user_id,
        message_id
      FROM post_views
      GROUP BY user_id, message_id
      HAVING COUNT(*) > 1
    )
    DELETE FROM post_views AS pv
    USING duplicates
    WHERE
      pv.user_id = duplicates.user_id AND
      pv.message_id = duplicates.message_id AND
      pv.id <> duplicates.keep_id
    """)

    drop_if_exists index(:post_views, [:user_id, :message_id])
    create unique_index(:post_views, [:user_id, :message_id])
  end

  def down do
    drop_if_exists unique_index(:post_views, [:user_id, :message_id])
    create index(:post_views, [:user_id, :message_id])
  end
end
