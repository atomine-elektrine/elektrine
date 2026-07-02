defmodule Elektrine.Repo.Migrations.CreateSocialMessageStats do
  use Ecto.Migration

  def change do
    create table(:social_message_stats) do
      add :message_id, references(:social_messages, on_delete: :delete_all), null: false
      add :like_count, :integer, null: false, default: 0
      add :reply_count, :integer, null: false, default: 0
      add :share_count, :integer, null: false, default: 0
      add :quote_count, :integer, null: false, default: 0
      add :remote_like_count, :integer
      add :remote_reply_count, :integer
      add :remote_share_count, :integer
      add :remote_quote_count, :integer
      add :remote_counts_fetched_at, :utc_datetime

      timestamps()
    end

    create unique_index(:social_message_stats, [:message_id])
    create index(:social_message_stats, [:remote_counts_fetched_at])

    execute("""
    INSERT INTO social_message_stats (
      message_id,
      like_count,
      reply_count,
      share_count,
      quote_count,
      remote_like_count,
      remote_reply_count,
      remote_share_count,
      remote_quote_count,
      remote_counts_fetched_at,
      inserted_at,
      updated_at
    )
    SELECT
      id,
      GREATEST(COALESCE(like_count, 0), 0),
      GREATEST(COALESCE(reply_count, 0), 0),
      GREATEST(COALESCE(share_count, 0), 0),
      GREATEST(COALESCE(quote_count, 0), 0),
      CASE
        WHEN remote_like_count IS NULL OR remote_like_count <= 0 THEN NULL
        ELSE LEAST(remote_like_count, 100000000)
      END,
      CASE
        WHEN remote_reply_count IS NULL OR remote_reply_count <= 0 THEN NULL
        ELSE LEAST(remote_reply_count, 100000000)
      END,
      CASE
        WHEN remote_share_count IS NULL OR remote_share_count <= 0 THEN NULL
        ELSE LEAST(remote_share_count, 100000000)
      END,
      CASE
        WHEN remote_quote_count IS NULL OR remote_quote_count <= 0 THEN NULL
        ELSE LEAST(remote_quote_count, 100000000)
      END,
      remote_counts_fetched_at,
      NOW(),
      NOW()
    FROM social_messages
    ON CONFLICT (message_id) DO NOTHING
    """)
  end
end
