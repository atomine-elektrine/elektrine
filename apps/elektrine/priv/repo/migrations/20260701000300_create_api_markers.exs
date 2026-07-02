defmodule Elektrine.Repo.Migrations.CreateApiMarkers do
  use Ecto.Migration

  def change do
    create table(:api_markers) do
      add :timeline, :string, null: false
      add :last_read_id, :string, null: false
      add :version, :integer, null: false, default: 0
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_markers, [:user_id, :timeline])
    create index(:api_markers, [:user_id])
  end
end
