defmodule Elektrine.Repo.Migrations.CreateClientAppSettings do
  use Ecto.Migration

  def change do
    create table(:client_app_settings) do
      add :app, :string, null: false
      add :settings, :map, null: false, default: %{}
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:client_app_settings, [:user_id, :app])
    create index(:client_app_settings, [:app])
  end
end
