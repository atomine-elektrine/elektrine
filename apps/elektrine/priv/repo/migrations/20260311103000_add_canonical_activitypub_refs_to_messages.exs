defmodule Elektrine.Repo.Migrations.AddCanonicalActivitypubRefsToMessages do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:messages) do
      add_if_not_exists :activitypub_id_canonical, :text
      add_if_not_exists :activitypub_url_canonical, :text
    end

    flush()

    execute("""
    UPDATE messages
    SET activitypub_id_canonical =
          NULLIF(trim(trailing '/' from split_part(split_part(btrim(activitypub_id), '#', 1), '?', 1)), ''),
        activitypub_url_canonical =
          NULLIF(trim(trailing '/' from split_part(split_part(btrim(activitypub_url), '#', 1), '?', 1)), '')
    WHERE activitypub_id IS NOT NULL
       OR activitypub_url IS NOT NULL
    """)

    create_if_not_exists index(:messages, [:activitypub_id_canonical],
                           concurrently: true,
                           where: "activitypub_id_canonical IS NOT NULL",
                           name: :messages_activitypub_id_canonical_idx
                         )

    create_if_not_exists index(:messages, [:activitypub_url_canonical],
                           concurrently: true,
                           where: "activitypub_url_canonical IS NOT NULL",
                           name: :messages_activitypub_url_canonical_idx
                         )
  end

  def down do
    drop_if_exists index(:messages, [:activitypub_id_canonical],
                     concurrently: true,
                     name: :messages_activitypub_id_canonical_idx
                   )

    drop_if_exists index(:messages, [:activitypub_url_canonical],
                     concurrently: true,
                     name: :messages_activitypub_url_canonical_idx
                   )

    alter table(:messages) do
      remove :activitypub_id_canonical
      remove :activitypub_url_canonical
    end
  end
end
