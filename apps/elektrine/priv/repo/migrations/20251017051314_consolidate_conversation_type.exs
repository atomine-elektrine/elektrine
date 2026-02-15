defmodule Elektrine.Repo.Migrations.ConsolidateConversationType do
  use Ecto.Migration

  def up do
    # Update conversations where space_type is "timeline" to have type "timeline"
    execute """
    UPDATE conversations
    SET type = 'timeline'
    WHERE space_type = 'timeline'
    """

    # Update conversations where space_type is "community" to have type "community"
    execute """
    UPDATE conversations
    SET type = 'community'
    WHERE space_type = 'community'
    """

    # For chat space_type (or null), the type field already has the correct value (dm/group/channel)
    # So no update needed for those

    # Remove the space_type column since it's now redundant
    # Keep community-related fields as they're still useful for type = "community"
    alter table(:conversations) do
      remove :space_type
    end
  end

  def down do
    # Re-add the space_type column
    alter table(:conversations) do
      add :space_type, :string, default: "chat"
    end

    # Restore space_type based on type
    execute """
    UPDATE conversations
    SET space_type = 'timeline'
    WHERE type = 'timeline'
    """

    execute """
    UPDATE conversations
    SET space_type = 'community'
    WHERE type = 'community'
    """

    execute """
    UPDATE conversations
    SET space_type = 'chat'
    WHERE type IN ('dm', 'group', 'channel')
    """
  end
end
