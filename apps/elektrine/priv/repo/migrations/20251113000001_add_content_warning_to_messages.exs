defmodule Elektrine.Repo.Migrations.AddContentWarningToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :content_warning, :string
      add :sensitive, :boolean, default: false
    end

    # Add index for querying sensitive content
    create index(:messages, [:sensitive])
  end
end
