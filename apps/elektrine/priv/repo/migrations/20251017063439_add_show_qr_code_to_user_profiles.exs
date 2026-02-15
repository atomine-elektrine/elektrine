defmodule Elektrine.Repo.Migrations.AddShowQrCodeToUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :show_qr_code, :boolean, default: false
    end
  end
end
