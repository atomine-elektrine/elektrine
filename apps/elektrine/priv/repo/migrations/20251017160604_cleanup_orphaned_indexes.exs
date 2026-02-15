defmodule Elektrine.Repo.Migrations.CleanupOrphanedIndexes do
  use Ecto.Migration

  def change do
    # Drop orphaned indexes from removed screener feature
    # These columns (screener_status, sender_approved) were removed in 20250726184803_remove_screener_feature.exs
    # but the indexes may still exist if the migration didn't fully clean them up
    drop_if_exists index(:email_messages, [:screener_status])
    drop_if_exists index(:email_messages, [:sender_approved])

    # Drop orphaned index from renamed column
    # set_aside_at was renamed to stack_at in 20250927161505_rename_email_categories.exs
    # but the old index may still exist
    drop_if_exists index(:email_messages, [:set_aside_at])

    # Drop indexes for approved_senders table (being dropped in previous migration)
    drop_if_exists index(:approved_senders, [:mailbox_id])
    drop_if_exists index(:approved_senders, [:email_address])
    drop_if_exists index(:approved_senders, [:email_address, :mailbox_id])
  end
end
