defmodule Elektrine.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :locale, :string, size: 5, default: "en"
    end
  end
end
