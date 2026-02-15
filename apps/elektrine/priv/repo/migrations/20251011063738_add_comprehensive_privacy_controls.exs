defmodule Elektrine.Repo.Migrations.AddComprehensivePrivacyControls do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Call privacy settings
      add :allow_calls_from, :string, default: "friends"
      # Options: "everyone", "friends", "nobody"

      # Friend request privacy
      add :allow_friend_requests_from, :string, default: "everyone"
      # Options: "everyone", "followers", "nobody"

      # Timeline post visibility (separate from profile_visibility)
      add :default_post_visibility, :string, default: "followers"
      # Options: "public", "followers", "friends", "private"
    end
  end
end
