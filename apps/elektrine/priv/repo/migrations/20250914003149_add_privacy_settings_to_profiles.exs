defmodule Elektrine.Repo.Migrations.AddPrivacySettingsToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :hide_view_counter, :boolean, default: false
      add :hide_uid, :boolean, default: false
    end
  end
end
