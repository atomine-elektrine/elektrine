defmodule Elektrine.Repo.Migrations.AddPastebinOptionsToNoteShares do
  use Ecto.Migration

  def change do
    alter table(:note_shares) do
      add :expires_at, :utc_datetime
      add :burn_after_read, :boolean, null: false, default: false
    end

    create index(:note_shares, [:expires_at])
  end
end
