defmodule Elektrine.Repo.Migrations.AddTimeFormatToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :time_format, :string, default: "12"
    end
  end
end
