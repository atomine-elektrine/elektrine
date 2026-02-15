defmodule Elektrine.Repo.Migrations.MakeMessageReactionsUserIdNullable do
  use Ecto.Migration

  def change do
    alter table(:message_reactions) do
      # Drop the NOT NULL without touching the existing foreign key to avoid
      # recreating the constraint and hitting "constraint already exists"
      modify :user_id, :bigint, null: true, from: {:bigint, null: false}
    end
  end
end
