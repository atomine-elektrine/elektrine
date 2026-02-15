defmodule Elektrine.Repo.Migrations.CreateHashtagFollows do
  use Ecto.Migration

  def change do
    create table(:hashtag_follows) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:hashtag_id, references(:hashtags, on_delete: :delete_all), null: false)

      timestamps()
    end

    create(unique_index(:hashtag_follows, [:user_id, :hashtag_id]))
    create(index(:hashtag_follows, [:hashtag_id]))
  end
end
