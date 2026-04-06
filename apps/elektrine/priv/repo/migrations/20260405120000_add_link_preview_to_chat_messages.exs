defmodule Elektrine.Repo.Migrations.AddLinkPreviewToChatMessages do
  use Ecto.Migration

  def change do
    alter table(:chat_messages) do
      add :link_preview_id, references(:link_previews, on_delete: :nilify_all)
    end

    create index(:chat_messages, [:link_preview_id])
  end
end
