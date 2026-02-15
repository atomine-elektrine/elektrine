defmodule Elektrine.Repo.Migrations.CreateUserBadges do
  use Ecto.Migration

  def change do
    create table(:user_badges) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :badge_type, :string, null: false
      add :badge_text, :string
      add :badge_color, :string, default: "#8b5cf6"
      add :badge_icon, :string
      add :tooltip, :string
      add :granted_by_id, references(:users, on_delete: :nilify_all)
      add :position, :integer, default: 0

      timestamps()
    end

    create index(:user_badges, [:user_id])
    create index(:user_badges, [:badge_type])
  end
end
