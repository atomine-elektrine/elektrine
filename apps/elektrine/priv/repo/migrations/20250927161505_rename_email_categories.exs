defmodule Elektrine.Repo.Migrations.RenameEmailCategories do
  use Ecto.Migration

  def change do
    # Update category values from paper_trail to ledger
    execute """
              UPDATE email_messages
              SET category = 'ledger'
              WHERE category = 'paper_trail'
            """,
            """
              UPDATE email_messages
              SET category = 'paper_trail'
              WHERE category = 'ledger'
            """

    # Update category values from set_aside to stack
    execute """
              UPDATE email_messages
              SET category = 'stack'
              WHERE category = 'set_aside'
            """,
            """
              UPDATE email_messages
              SET category = 'set_aside'
              WHERE category = 'stack'
            """

    # Rename set_aside columns to stack
    rename table(:email_messages), :set_aside_at, to: :stack_at
    rename table(:email_messages), :set_aside_reason, to: :stack_reason
  end
end
