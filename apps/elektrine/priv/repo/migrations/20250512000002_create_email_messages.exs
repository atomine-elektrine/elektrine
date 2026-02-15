defmodule Elektrine.Repo.Migrations.CreateEmailMessages do
  use Ecto.Migration

  def change do
    create table(:email_messages) do
      add :message_id, :string, null: false
      add :from, :string, null: false
      add :to, :string, null: false
      add :cc, :string
      add :bcc, :string
      add :subject, :string
      add :text_body, :text
      add :html_body, :text
      add :status, :string, null: false, default: "received"
      add :read, :boolean, default: false
      add :metadata, :map, default: %{}
      add :mailbox_id, references(:mailboxes, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:email_messages, [:message_id, :mailbox_id])
    create index(:email_messages, [:mailbox_id])
    create index(:email_messages, [:status])
    create index(:email_messages, [:from])
    create index(:email_messages, [:to])
  end
end
