defmodule Elektrine.Repo.Migrations.AddEncryptionToEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      add :encrypted_text_body, :map
      add :encrypted_html_body, :map
      add :search_index, {:array, :text}, default: []
    end

    create index(:email_messages, [:search_index], using: :gin)
  end
end
