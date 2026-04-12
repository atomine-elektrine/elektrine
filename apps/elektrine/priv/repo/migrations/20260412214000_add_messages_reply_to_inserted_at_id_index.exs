defmodule Elektrine.Repo.Migrations.AddMessagesReplyToInsertedAtIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists index(:messages, [:reply_to_id, :inserted_at, :id],
                           name: :messages_reply_to_id_inserted_at_id_idx,
                           concurrently: true,
                           where: "reply_to_id IS NOT NULL"
                         )
  end
end
