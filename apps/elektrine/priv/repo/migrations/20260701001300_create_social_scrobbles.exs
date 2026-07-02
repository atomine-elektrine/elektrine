defmodule Elektrine.Repo.Migrations.CreateSocialScrobbles do
  use Ecto.Migration

  def change do
    create table(:social_scrobbles) do
      add :title, :string, null: false
      add :artist, :string
      add :album, :string
      add :length, :integer
      add :external_link, :text
      add :visibility, :string, null: false, default: "public"
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:social_scrobbles, [:user_id, :inserted_at])
    create index(:social_scrobbles, [:visibility, :inserted_at])
  end
end
