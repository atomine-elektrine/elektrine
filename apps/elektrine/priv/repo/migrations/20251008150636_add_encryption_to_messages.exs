defmodule Elektrine.Repo.Migrations.AddEncryptionToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :encrypted_content, :map
      add :search_index, {:array, :text}, default: []
    end

    create index(:messages, [:search_index], using: :gin)
  end
end
