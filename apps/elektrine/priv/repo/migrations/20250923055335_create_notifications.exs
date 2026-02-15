defmodule Elektrine.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :type, :string, null: false

      # Types: new_message, mention, reply, follow, like, comment, discussion_reply, email_received, system

      add :title, :string, null: false
      add :body, :text
      # Where to navigate when clicked
      add :url, :string
      # Icon name or URL
      add :icon, :string
      # low, normal, high, urgent
      add :priority, :string, default: "normal"

      add :read_at, :utc_datetime
      add :seen_at, :utc_datetime
      add :dismissed_at, :utc_datetime

      # References
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Who triggered the notification
      add :actor_id, references(:users, on_delete: :nilify_all)

      # Polymorphic reference to the source
      # "message", "post", "discussion", "email", etc.
      add :source_type, :string
      add :source_id, :integer

      # Additional metadata
      add :metadata, :map, default: %{}

      timestamps()
    end

    create index(:notifications, [:user_id])
    create index(:notifications, [:user_id, :read_at])
    create index(:notifications, [:user_id, :type])
    create index(:notifications, [:source_type, :source_id])
    create index(:notifications, [:inserted_at])
  end
end
