defmodule Elektrine.RSS.Feed do
  @moduledoc """
  Schema for RSS/Atom feeds.
  Stores feed metadata and fetch status.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "rss_feeds" do
    field :url, :string
    field :title, :string
    field :description, :string
    field :site_url, :string
    field :favicon_url, :string
    field :image_url, :string
    field :last_fetched_at, :utc_datetime
    field :last_error, :string
    field :fetch_interval_minutes, :integer, default: 60
    field :status, :string, default: "active"
    field :etag, :string
    field :last_modified, :string

    has_many :subscriptions, Elektrine.RSS.Subscription
    has_many :items, Elektrine.RSS.Item

    timestamps()
  end

  @doc false
  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :url,
      :title,
      :description,
      :site_url,
      :favicon_url,
      :image_url,
      :last_fetched_at,
      :last_error,
      :fetch_interval_minutes,
      :status,
      :etag,
      :last_modified
    ])
    |> validate_required([:url])
    |> unique_constraint(:url)
    |> validate_inclusion(:status, ["pending", "active", "paused", "error"])
  end

  @doc """
  Changeset for updating feed metadata after a successful fetch.
  """
  def metadata_changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :title,
      :description,
      :site_url,
      :favicon_url,
      :image_url,
      :etag,
      :last_modified
    ])
  end

  @doc """
  Changeset for marking a feed as fetched.
  """
  def fetched_changeset(feed, attrs \\ %{}) do
    feed
    |> cast(attrs, [:last_fetched_at, :last_error, :status, :etag, :last_modified])
    |> put_change(:last_fetched_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> put_change(:last_error, nil)
    |> put_change(:status, "active")
  end

  @doc """
  Changeset for recording a fetch error.
  """
  def error_changeset(feed, error_message) do
    feed
    |> change()
    |> put_change(:last_error, error_message)
    |> put_change(:status, "error")
  end
end
