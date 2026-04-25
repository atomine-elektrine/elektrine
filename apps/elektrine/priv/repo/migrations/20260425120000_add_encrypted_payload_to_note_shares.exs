defmodule Elektrine.Repo.Migrations.AddEncryptedPayloadToNoteShares do
  use Ecto.Migration

  def change do
    alter table(:note_shares) do
      add :encrypted_payload, :map
    end
  end
end
