defmodule Elektrine.Repo.Migrations.ChangeActivitypubFieldsToText do
  use Ecto.Migration

  def change do
    # Change activitypub_id and activitypub_url from varchar(255) to text
    # ActivityPub IDs can be very long URLs from various instances
    alter table(:messages) do
      modify :activitypub_id, :text
      modify :activitypub_url, :text
      modify :content_warning, :text
    end

    alter table(:follows) do
      modify :activitypub_id, :text
    end

    alter table(:post_boosts) do
      modify :activitypub_id, :text
    end

    alter table(:federated_likes) do
      modify :activitypub_id, :text
    end
  end
end
