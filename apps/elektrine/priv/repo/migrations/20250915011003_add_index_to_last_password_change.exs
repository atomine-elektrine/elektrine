defmodule Elektrine.Repo.Migrations.AddIndexToLastPasswordChange do
  use Ecto.Migration

  def change do
    create index(:users, [:last_password_change])
  end
end
