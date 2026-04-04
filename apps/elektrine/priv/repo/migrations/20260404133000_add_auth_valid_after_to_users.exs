defmodule Elektrine.Repo.Migrations.AddAuthValidAfterToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :auth_valid_after, :utc_datetime
    end
  end
end
