defmodule Elektrine.Repo.Migrations.AddAvatarEffectToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :avatar_effect, :string, default: "none"
    end
  end
end
