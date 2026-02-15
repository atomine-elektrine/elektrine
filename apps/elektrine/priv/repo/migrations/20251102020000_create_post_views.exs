defmodule Elektrine.Repo.Migrations.CreatePostViews do
  use Ecto.Migration

  def change do
    create table(:post_views) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      # How long they viewed it
      add :view_duration_seconds, :integer
      # Did they scroll to bottom / view fully
      add :completed, :boolean, default: false

      # Only track created_at, views don't update
      timestamps(updated_at: false)
    end

    create index(:post_views, [:user_id])
    create index(:post_views, [:message_id])
    create index(:post_views, [:user_id, :message_id])
    create index(:post_views, [:inserted_at])
  end
end
