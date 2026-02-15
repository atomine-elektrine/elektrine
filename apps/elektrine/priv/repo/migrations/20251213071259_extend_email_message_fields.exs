defmodule Elektrine.Repo.Migrations.ExtendEmailMessageFields do
  use Ecto.Migration

  def change do
    # Extend email address fields to support many recipients
    # to/cc/bcc can have many addresses, so use text
    alter table(:email_messages) do
      modify :from, :string, size: 500
      modify :to, :text
      modify :cc, :text
      modify :bcc, :text
      modify :subject, :string, size: 500
      modify :message_id, :string, size: 500
    end
  end
end
