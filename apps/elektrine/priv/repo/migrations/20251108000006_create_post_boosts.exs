defmodule Elektrine.Repo.Migrations.CreatePostBoosts do
  use Ecto.Migration

  def change do
    create table(:post_boosts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      # Track the Announce activity ID
      add :activitypub_id, :string

      timestamps(type: :naive_datetime)
    end

    create unique_index(:post_boosts, [:user_id, :message_id])
    create index(:post_boosts, [:message_id])
    create index(:post_boosts, [:user_id])
    create index(:post_boosts, [:activitypub_id])
  end
end
