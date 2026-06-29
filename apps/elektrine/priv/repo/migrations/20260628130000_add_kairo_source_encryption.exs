defmodule Elektrine.Repo.Migrations.AddKairoSourceEncryption do
  use Ecto.Migration

  def change do
    alter table(:kairo_sources) do
      add :encrypted, :boolean, null: false, default: false
      add :encrypted_content, :map
    end
  end
end
