defmodule Elektrine.Repo.Migrations.BackfillServerChannelVisibility do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE conversations
    SET is_public = TRUE
    WHERE type = 'channel'
      AND server_id IS NOT NULL
      AND is_public = FALSE
    """)
  end

  def down do
    :ok
  end
end
