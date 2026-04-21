defmodule Elektrine.Repo.Migrations.CreateNoteShares do
  use Ecto.Migration

  def change do
    create table(:note_shares) do
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :revoked_at, :utc_datetime
      add :view_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:note_shares, [:token])
    create index(:note_shares, [:note_id])
    create index(:note_shares, [:user_id, :note_id])
  end
end
