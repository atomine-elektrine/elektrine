defmodule Elektrine.Repo.Migrations.AddRecoveryEmailToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :recovery_email, :string
      add :password_reset_token, :string
      add :password_reset_token_expires_at, :utc_datetime
    end

    create index(:users, [:password_reset_token], unique: true)
  end
end
