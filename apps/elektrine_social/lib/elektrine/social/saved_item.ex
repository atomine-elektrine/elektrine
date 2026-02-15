defmodule Elektrine.Social.SavedItem do
  @moduledoc """
  Schema for saved/bookmarked items.
  Supports both regular posts (messages) and RSS items.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "saved_items" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :message, Elektrine.Messaging.Message
    belongs_to :rss_item, Elektrine.RSS.Item

    field :folder, :string
    field :notes, :string

    timestamps()
  end

  @doc """
  Changeset for saving a message (post).
  """
  def message_changeset(saved_item, attrs) do
    saved_item
    |> cast(attrs, [:user_id, :message_id, :folder, :notes])
    |> validate_required([:user_id, :message_id])
    |> unique_constraint([:user_id, :message_id], name: :saved_items_user_message_unique)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:message_id)
  end

  @doc """
  Changeset for saving an RSS item.
  """
  def rss_item_changeset(saved_item, attrs) do
    saved_item
    |> cast(attrs, [:user_id, :rss_item_id, :folder, :notes])
    |> validate_required([:user_id, :rss_item_id])
    |> unique_constraint([:user_id, :rss_item_id], name: :saved_items_user_rss_item_unique)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:rss_item_id)
  end
end
