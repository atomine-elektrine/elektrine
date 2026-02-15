defmodule Elektrine.RSS.Item do
  @moduledoc """
  Schema for individual RSS/Atom feed items.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "rss_items" do
    belongs_to :feed, Elektrine.RSS.Feed

    field :guid, :string
    field :title, :string
    field :content, :string
    field :summary, :string
    field :url, :string
    field :author, :string
    field :published_at, :utc_datetime
    field :image_url, :string
    field :enclosure_url, :string
    field :enclosure_type, :string
    field :categories, {:array, :string}, default: []

    timestamps()
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :feed_id,
      :guid,
      :title,
      :content,
      :summary,
      :url,
      :author,
      :published_at,
      :image_url,
      :enclosure_url,
      :enclosure_type,
      :categories
    ])
    |> validate_required([:feed_id, :guid])
    |> unique_constraint([:feed_id, :guid])
    |> foreign_key_constraint(:feed_id)
  end
end
