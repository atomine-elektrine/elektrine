defmodule Elektrine.Messaging.ChannelCategory do
  @moduledoc """
  Schema for channel categories inside a community server.

  Categories group a server's channels in the sidebar. Channels reference a
  category through `chat_conversations.category_id`; deleting a category
  nullifies that reference without deleting the channels.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_channel_categories" do
    field :name, :string
    field :position, :integer, default: 0

    belongs_to :server, Elektrine.Messaging.Server

    has_many :channels, Elektrine.Messaging.ChatConversation, foreign_key: :category_id

    timestamps()
  end

  @doc false
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :position, :server_id])
    |> validate_required([:name, :server_id])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 80)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:server_id)
  end
end
