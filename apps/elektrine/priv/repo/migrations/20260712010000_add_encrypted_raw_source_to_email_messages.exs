defmodule Elektrine.Repo.Migrations.AddEncryptedRawSourceToEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      add :encrypted_raw_source, :map
    end
  end
end
