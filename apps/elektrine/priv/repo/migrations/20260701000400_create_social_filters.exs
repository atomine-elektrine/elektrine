defmodule Elektrine.Repo.Migrations.CreateSocialFilters do
  use Ecto.Migration

  def change do
    create table(:social_filters) do
      add :kind, :string, null: false
      add :value, :text
      add :contexts, {:array, :string}, null: false, default: []
      add :action, :string, null: false, default: "hide"
      add :whole_word, :boolean, null: false, default: false
      add :expires_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:social_filters, [:user_id, :kind])
    create index(:social_filters, [:user_id, :expires_at])
  end
end
