defmodule Elektrine.Repo.Migrations.CreateRssAndSavedItems do
  use Ecto.Migration

  def change do
    # RSS Feeds - global catalog of known feeds
    create table(:rss_feeds) do
      add :url, :text, null: false
      add :title, :string
      add :description, :text
      add :site_url, :string
      add :favicon_url, :string
      add :image_url, :string
      add :last_fetched_at, :utc_datetime
      add :last_error, :text
      add :fetch_interval_minutes, :integer, default: 60
      add :status, :string, default: "active"
      add :etag, :string
      add :last_modified, :string

      timestamps()
    end

    create unique_index(:rss_feeds, [:url])
    create index(:rss_feeds, [:status])
    create index(:rss_feeds, [:last_fetched_at])

    # RSS Subscriptions - per-user feed subscriptions
    create table(:rss_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :feed_id, references(:rss_feeds, on_delete: :delete_all), null: false
      add :display_name, :string
      add :folder, :string
      add :notify_new_items, :boolean, default: false
      add :show_in_timeline, :boolean, default: true

      timestamps()
    end

    create unique_index(:rss_subscriptions, [:user_id, :feed_id])
    create index(:rss_subscriptions, [:user_id])
    create index(:rss_subscriptions, [:feed_id])

    # RSS Items - individual feed entries
    create table(:rss_items) do
      add :feed_id, references(:rss_feeds, on_delete: :delete_all), null: false
      add :guid, :string, null: false
      add :title, :string
      add :content, :text
      add :summary, :text
      add :url, :text
      add :author, :string
      add :published_at, :utc_datetime
      add :image_url, :string
      add :enclosure_url, :text
      add :enclosure_type, :string
      add :categories, {:array, :string}, default: []

      timestamps()
    end

    create unique_index(:rss_items, [:feed_id, :guid])
    create index(:rss_items, [:feed_id])
    create index(:rss_items, [:published_at])
    create index(:rss_items, [:inserted_at])

    # Saved Items - bookmarks for messages and RSS items (polymorphic)
    create table(:saved_items) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all)
      add :rss_item_id, references(:rss_items, on_delete: :delete_all)
      add :folder, :string
      add :notes, :text

      timestamps()
    end

    # Unique indexes - only one bookmark per user per item
    create unique_index(:saved_items, [:user_id, :message_id],
             where: "message_id IS NOT NULL",
             name: :saved_items_user_message_unique
           )

    create unique_index(:saved_items, [:user_id, :rss_item_id],
             where: "rss_item_id IS NOT NULL",
             name: :saved_items_user_rss_item_unique
           )

    create index(:saved_items, [:user_id])
    create index(:saved_items, [:inserted_at])

    # Constraint: exactly one of message_id or rss_item_id must be set
    create constraint(:saved_items, :saved_items_one_reference,
             check:
               "(message_id IS NOT NULL AND rss_item_id IS NULL) OR (message_id IS NULL AND rss_item_id IS NOT NULL)"
           )
  end
end
