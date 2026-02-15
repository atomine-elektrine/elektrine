defmodule Elektrine.Repo.Migrations.AddPinnedToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :is_pinned, :boolean, default: false
      add :pinned_at, :utc_datetime
      add :pinned_by_id, references(:users, on_delete: :nilify_all)
    end

    create index(:messages, [:conversation_id, :is_pinned])
  end
end
