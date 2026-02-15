defmodule Elektrine.Repo.Migrations.RenameFeedToDigest do
  use Ecto.Migration

  def change do
    # Update category values from feed to digest
    execute """
              UPDATE email_messages
              SET category = 'digest'
              WHERE category = 'feed'
            """,
            """
              UPDATE email_messages
              SET category = 'feed'
              WHERE category = 'digest'
            """
  end
end
