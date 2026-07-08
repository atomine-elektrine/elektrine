defmodule Elektrine.Repo.Migrations.DedupeHashtagsByNormalizedName do
  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS hashtags_normalized_name_index")
    execute("DROP INDEX IF EXISTS hashtags_normalized_name_idx")

    execute("""
    CREATE TEMP TABLE hashtag_dedupe_map ON COMMIT DROP AS
    WITH normalized AS (
      SELECT
        id,
        lower(trim(normalized_name)) AS canonical_name
      FROM hashtags
    ),
    keepers AS (
      SELECT
        canonical_name,
        min(id) AS keep_id
      FROM normalized
      GROUP BY canonical_name
    )
    SELECT
      normalized.id AS old_id,
      keepers.keep_id,
      normalized.canonical_name
    FROM normalized
    JOIN keepers USING (canonical_name)
    """)

    execute("CREATE INDEX hashtag_dedupe_map_old_id_idx ON hashtag_dedupe_map (old_id)")
    execute("CREATE INDEX hashtag_dedupe_map_keep_id_idx ON hashtag_dedupe_map (keep_id)")

    execute("""
    WITH stats AS (
      SELECT
        dedupe.keep_id,
        max(dedupe.canonical_name) AS canonical_name,
        sum(coalesce(hashtags.use_count, 0)) AS use_count,
        max(hashtags.last_used_at) AS last_used_at
      FROM hashtag_dedupe_map dedupe
      JOIN hashtags ON hashtags.id = dedupe.old_id
      GROUP BY dedupe.keep_id
    )
    UPDATE hashtags
    SET
      normalized_name = stats.canonical_name,
      use_count = stats.use_count,
      last_used_at = stats.last_used_at,
      updated_at = now()
    FROM stats
    WHERE hashtags.id = stats.keep_id
    """)

    execute("""
    INSERT INTO post_hashtags (message_id, hashtag_id, inserted_at)
    SELECT
      post_hashtags.message_id,
      dedupe.keep_id,
      min(post_hashtags.inserted_at)
    FROM post_hashtags
    JOIN hashtag_dedupe_map dedupe ON dedupe.old_id = post_hashtags.hashtag_id
    WHERE dedupe.old_id <> dedupe.keep_id
    GROUP BY post_hashtags.message_id, dedupe.keep_id
    ON CONFLICT (message_id, hashtag_id) DO NOTHING
    """)

    execute("""
    DELETE FROM post_hashtags
    USING hashtag_dedupe_map dedupe
    WHERE post_hashtags.hashtag_id = dedupe.old_id
      AND dedupe.old_id <> dedupe.keep_id
    """)

    execute("""
    DELETE FROM hashtags
    USING hashtag_dedupe_map dedupe
    WHERE hashtags.id = dedupe.old_id
      AND dedupe.old_id <> dedupe.keep_id
    """)

    create_if_not_exists(index(:hashtags, [:normalized_name], unique: true))
  end

  def down do
    :ok
  end
end
