defmodule Elektrine.Repo.Migrations.BackfillMessagesCanonicalActivitypubRefs do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE messages
    SET activitypub_id_canonical =
          COALESCE(
            activitypub_id_canonical,
            NULLIF(trim(trailing '/' from split_part(split_part(btrim(activitypub_id), '#', 1), '?', 1)), '')
          ),
        activitypub_url_canonical =
          COALESCE(
            activitypub_url_canonical,
            NULLIF(trim(trailing '/' from split_part(split_part(btrim(activitypub_url), '#', 1), '?', 1)), '')
          )
    WHERE (activitypub_id IS NOT NULL AND activitypub_id_canonical IS NULL)
       OR (activitypub_url IS NOT NULL AND activitypub_url_canonical IS NULL)
    """)
  end

  def down do
    :ok
  end
end
