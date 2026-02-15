defmodule Elektrine.Repo.Migrations.AddLastPasswordChangeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_password_change, :utc_datetime
    end
  end
end
