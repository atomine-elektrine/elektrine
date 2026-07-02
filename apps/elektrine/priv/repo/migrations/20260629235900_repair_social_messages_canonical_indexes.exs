defmodule Elektrine.Repo.Migrations.RepairSocialMessagesCanonicalIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Rebuilds the canonical-ref indexes on social_messages from the heap.

  Production hit XX002 index_corrupted on messages_activitypub_url_canonical_idx:
  the btree page ordering is broken, so any non-HOT row update fails when it
  inserts its new index entry. This must run before the engagement-counts
  backfill rewrites those rows. A plain (locking) REINDEX is used because it
  is the reliable repair for physical corruption; these indexes rebuild in
  seconds relative to deploy time.
  """

  def up do
    execute("REINDEX INDEX messages_activitypub_url_canonical_idx")
    execute("REINDEX INDEX messages_activitypub_id_canonical_idx")
  end

  def down do
    :ok
  end
end
