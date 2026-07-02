defmodule Elektrine.Repo.Migrations.ReindexMessagesActivitypubIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Rebuilds the partial unique index on social_messages.activitypub_id.

  On databases where a concurrent build of this index once failed, the index
  is marked INVALID: it still rejects writes but silently allowed duplicate
  rows to accumulate. The previous migration cleared those duplicates; this
  rebuild makes the index valid so uniqueness is actually enforced again.
  """

  def up do
    execute("REINDEX INDEX CONCURRENTLY messages_activitypub_id_index")
  end

  def down do
    :ok
  end
end
