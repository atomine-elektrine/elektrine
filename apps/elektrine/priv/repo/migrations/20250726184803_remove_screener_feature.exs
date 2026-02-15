defmodule Elektrine.Repo.Migrations.RemoveScreenerFeature do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      remove :screener_status
      remove :sender_approved
    end

    drop_if_exists index(:email_messages, [:screener_status])
    drop_if_exists index(:email_messages, [:sender_approved])

    drop_if_exists table(:rejected_senders)
  end
end
