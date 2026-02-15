defmodule Elektrine.Repo.Migrations.CreateProfileWidgets do
  use Ecto.Migration

  def change do
    create table(:profile_widgets) do
      add :profile_id, references(:user_profiles, on_delete: :delete_all), null: false
      add :widget_type, :string, null: false
      add :title, :string
      add :content, :text
      add :url, :string
      add :position, :integer, default: 0
      add :is_active, :boolean, default: true
      add :settings, :map, default: %{}

      timestamps()
    end

    create index(:profile_widgets, [:profile_id])
    create index(:profile_widgets, [:widget_type])
    create index(:profile_widgets, [:position])
  end
end
