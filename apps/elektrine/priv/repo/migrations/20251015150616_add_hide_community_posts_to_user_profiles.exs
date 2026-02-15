defmodule Elektrine.Repo.Migrations.AddHideCommunityPostsToUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :hide_community_posts, :boolean, default: false, null: false
    end
  end
end
