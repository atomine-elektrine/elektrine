defmodule Elektrine.Repo.Migrations.AddPrivacySettingsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Privacy settings for group/channel additions
      add :allow_group_adds_from, :string, default: "everyone"
      # Options: "everyone", "following", "followers", "mutual", "nobody"

      # Privacy settings for direct messages
      add :allow_direct_messages_from, :string, default: "everyone"
      # Options: "everyone", "following", "followers", "mutual", "nobody"

      # Privacy settings for mentions
      add :allow_mentions_from, :string, default: "everyone"
      # Options: "everyone", "following", "followers", "mutual", "nobody"

      # Privacy settings for profile visibility
      add :profile_visibility, :string, default: "public"
      # Options: "public", "followers", "private"

      # Settings for notifications
      add :email_on_new_follower, :boolean, default: true
      add :email_on_direct_message, :boolean, default: true
      add :email_on_mention, :boolean, default: true
      add :email_on_group_invite, :boolean, default: true
    end
  end
end
