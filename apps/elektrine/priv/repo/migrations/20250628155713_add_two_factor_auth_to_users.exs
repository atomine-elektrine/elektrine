defmodule Elektrine.Repo.Migrations.AddTwoFactorAuthToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :two_factor_enabled, :boolean, default: false, null: false
      add :two_factor_secret, :string
      add :two_factor_backup_codes, {:array, :string}
      add :two_factor_enabled_at, :utc_datetime
    end
  end
end
