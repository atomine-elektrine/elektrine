defmodule Elektrine.RSS.Subscription do
  @moduledoc """
  Schema for user subscriptions to RSS feeds.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "rss_subscriptions" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :feed, Elektrine.RSS.Feed

    field :display_name, :string
    field :folder, :string
    field :notify_new_items, :boolean, default: false
    field :show_in_timeline, :boolean, default: true

    timestamps()
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :feed_id,
      :display_name,
      :folder,
      :notify_new_items,
      :show_in_timeline
    ])
    |> validate_required([:user_id, :feed_id])
    |> unique_constraint([:user_id, :feed_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:feed_id)
  end
end
