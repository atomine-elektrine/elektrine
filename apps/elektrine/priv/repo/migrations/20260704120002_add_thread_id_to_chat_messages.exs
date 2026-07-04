defmodule Elektrine.Repo.Migrations.AddThreadIdToChatMessages do
  use Ecto.Migration

  def change do
    alter table(:chat_messages) do
      add :thread_id, references(:chat_threads, on_delete: :delete_all)
    end

    create index(:chat_messages, [:thread_id], where: "thread_id IS NOT NULL")
  end
end
