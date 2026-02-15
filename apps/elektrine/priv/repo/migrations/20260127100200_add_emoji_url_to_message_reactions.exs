defmodule Elektrine.Repo.Migrations.AddEmojiUrlToMessageReactions do
  use Ecto.Migration

  def change do
    alter table(:message_reactions) do
      # URL for custom emoji images (for federated reactions with custom emoji)
      add(:emoji_url, :string)
    end

    # Index for grouping reactions by emoji (including custom emoji URL)
    create(index(:message_reactions, [:message_id, :emoji, :emoji_url]))
  end
end
