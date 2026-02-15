defmodule Elektrine.Repo.Migrations.AddJmapFieldsToMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      add :thread_id, references(:email_threads, on_delete: :nilify_all)
      add :in_reply_to, :string
      add :references, :text
      add :jmap_blob_id, :string
    end

    create index(:email_messages, [:thread_id])
    create index(:email_messages, [:jmap_blob_id])
    create index(:email_messages, [:in_reply_to])
  end
end
