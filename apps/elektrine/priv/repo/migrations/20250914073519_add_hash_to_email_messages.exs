defmodule Elektrine.Repo.Migrations.AddHashToEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      add :hash, :string, size: 32
    end

    create unique_index(:email_messages, [:hash])
  end
end
