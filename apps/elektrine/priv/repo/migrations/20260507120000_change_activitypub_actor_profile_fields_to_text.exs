defmodule Elektrine.Repo.Migrations.ChangeActivitypubActorProfileFieldsToText do
  use Ecto.Migration

  def up do
    alter table(:activitypub_actors) do
      modify :uri, :text
      modify :username, :text
      modify :domain, :text
      modify :display_name, :text
      modify :avatar_url, :text
      modify :header_url, :text
      modify :inbox_url, :text
      modify :outbox_url, :text
      modify :followers_url, :text
      modify :following_url, :text
      modify :moderators_url, :text
    end
  end

  def down do
    execute("""
    UPDATE activitypub_actors
    SET uri = left(uri, 255),
        username = left(username, 255),
        domain = left(domain, 255),
        display_name = left(display_name, 255),
        avatar_url = left(avatar_url, 255),
        header_url = left(header_url, 255),
        inbox_url = left(inbox_url, 255),
        outbox_url = left(outbox_url, 255),
        followers_url = left(followers_url, 255),
        following_url = left(following_url, 255),
        moderators_url = left(moderators_url, 255)
    """)

    alter table(:activitypub_actors) do
      modify :uri, :string
      modify :username, :string
      modify :domain, :string
      modify :display_name, :string
      modify :avatar_url, :string
      modify :header_url, :string
      modify :inbox_url, :string
      modify :outbox_url, :string
      modify :followers_url, :string
      modify :following_url, :string
      modify :moderators_url, :string
    end
  end
end
