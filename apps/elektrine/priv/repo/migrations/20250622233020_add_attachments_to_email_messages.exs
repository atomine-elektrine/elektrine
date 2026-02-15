defmodule Elektrine.Repo.Migrations.AddAttachmentsToEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      add :attachments, :map, default: %{}
      add :has_attachments, :boolean, default: false
    end

    create index(:email_messages, [:has_attachments])
  end
end
