defmodule Elektrine.Repo.Migrations.CreateMessagingChannelCategories do
  use Ecto.Migration

  def change do
    create table(:messaging_channel_categories) do
      add :name, :string, null: false
      add :position, :integer, null: false, default: 0
      add :server_id, references(:messaging_servers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messaging_channel_categories, [:server_id])
    create index(:messaging_channel_categories, [:server_id, :position])

    alter table(:chat_conversations) do
      add :category_id, references(:messaging_channel_categories, on_delete: :nilify_all)
    end

    create index(:chat_conversations, [:category_id])
  end
end
