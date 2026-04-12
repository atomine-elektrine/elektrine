defmodule Elektrine.Repo.Migrations.AddMessagesReplyToInsertedAtIdIndex do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:messages, [:reply_to_id, :inserted_at, :id],
                           name: :messages_reply_to_id_inserted_at_id_idx
                         )
  end
end
