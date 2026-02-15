defmodule Elektrine.Repo.Migrations.RemoveShowQrCodeFromUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      remove :show_qr_code
    end
  end
end
