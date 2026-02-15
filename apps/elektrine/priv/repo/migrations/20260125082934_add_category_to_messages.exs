defmodule Elektrine.Repo.Migrations.AddCategoryToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :category, :string
    end

    # Index for filtering gallery posts by category
    create index(:messages, [:category], where: "category IS NOT NULL")
  end
end
