defmodule Elektrine.Repo.Migrations.AddCaseInsensitiveCommunityNameIndex do
  use Ecto.Migration

  def change do
    # Drop the old case-sensitive unique index on community names
    drop_if_exists index(:conversations, [:name],
                     where: "space_type = 'community'",
                     name: :conversations_community_name_unique_index
                   )

    # Create case-insensitive unique index on community names
    create unique_index(:conversations, ["lower(name)"],
             where: "space_type = 'community'",
             name: :conversations_community_name_ci_unique
           )
  end
end
