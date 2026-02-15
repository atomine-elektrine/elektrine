defmodule Elektrine.Repo.Migrations.AddUniqueConstraintToCommunityNames do
  use Ecto.Migration

  def change do
    # Add unique index on name for community conversations only
    create unique_index(:conversations, [:name],
             where: "space_type = 'community'",
             name: :conversations_community_name_unique_index
           )
  end
end
