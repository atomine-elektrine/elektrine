defmodule Elektrine.Repo.Migrations.AddHashToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :hash, :string, size: 32
    end

    create unique_index(:conversations, [:hash])
  end
end
