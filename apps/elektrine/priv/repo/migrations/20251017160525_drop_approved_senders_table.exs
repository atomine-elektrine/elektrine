defmodule Elektrine.Repo.Migrations.DropApprovedSendersTable do
  use Ecto.Migration

  def change do
    # Drop the approved_senders table - orphaned after screener feature removal
    # This table was created in 20250608202829 but never removed when screener was removed
    drop_if_exists table(:approved_senders)
  end
end
