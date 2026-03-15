defmodule Elektrine.Repo.Migrations.AddMessagesActivitypubUrlLookupIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists index(:messages, [:activitypub_url],
                           concurrently: true,
                           where: "activitypub_url IS NOT NULL",
                           name: :messages_activitypub_url_not_null_idx
                         )
  end

  def down do
    drop_if_exists index(:messages, [:activitypub_url],
                     concurrently: true,
                     name: :messages_activitypub_url_not_null_idx
                   )
  end
end
