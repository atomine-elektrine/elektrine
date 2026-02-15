defmodule Elektrine.Repo.Migrations.AddTitlesToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :title, :string
      # true if title was auto-extracted from link
      add :auto_title, :boolean, default: false
    end

    create index(:messages, [:title])
  end
end
