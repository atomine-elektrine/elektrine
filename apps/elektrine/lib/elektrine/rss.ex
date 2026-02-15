defmodule Elektrine.RSS do
  @moduledoc """
  Context for RSS feed subscriptions and items.
  """

  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.RSS.{Feed, Subscription, Item}

  ## Feeds

  @doc """
  Gets or creates a feed by URL.
  """
  def get_or_create_feed(url) do
    normalized_url = normalize_url(url)

    case Repo.get_by(Feed, url: normalized_url) do
      nil ->
        %Feed{}
        |> Feed.changeset(%{url: normalized_url, status: "pending"})
        |> Repo.insert()

      feed ->
        {:ok, feed}
    end
  end

  @doc """
  Gets a feed by ID.
  """
  def get_feed(id), do: Repo.get(Feed, id)

  @doc """
  Gets a feed by URL.
  """
  def get_feed_by_url(url) do
    normalized_url = normalize_url(url)
    Repo.get_by(Feed, url: normalized_url)
  end

  @doc """
  Updates a feed.
  """
  def update_feed(%Feed{} = feed, attrs) do
    feed
    |> Feed.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Lists all feeds that need to be fetched (stale feeds).
  """
  def list_stale_feeds(limit \\ 50) do
    now = DateTime.utc_now()
    # Default threshold: feeds not fetched in the last 60 minutes
    threshold = DateTime.add(now, -60, :minute)

    from(f in Feed,
      where: f.status == "active",
      where: is_nil(f.last_fetched_at) or f.last_fetched_at < ^threshold,
      order_by: [asc: f.last_fetched_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  ## Subscriptions

  @doc """
  Subscribe a user to a feed URL.
  Creates the feed if it doesn't exist.
  """
  def subscribe(user_id, url, opts \\ []) do
    display_name = Keyword.get(opts, :display_name)
    folder = Keyword.get(opts, :folder)

    with {:ok, feed} <- get_or_create_feed(url) do
      %Subscription{}
      |> Subscription.changeset(%{
        user_id: user_id,
        feed_id: feed.id,
        display_name: display_name,
        folder: folder
      })
      |> Repo.insert()
      |> case do
        {:ok, subscription} -> {:ok, %{subscription | feed: feed}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Unsubscribe a user from a feed.
  """
  def unsubscribe(user_id, feed_id) do
    from(s in Subscription,
      where: s.user_id == ^user_id and s.feed_id == ^feed_id
    )
    |> Repo.delete_all()
    |> case do
      {0, _} -> {:error, :not_subscribed}
      {count, _} -> {:ok, count}
    end
  end

  @doc """
  Lists all subscriptions for a user.
  """
  def list_subscriptions(user_id) do
    from(s in Subscription,
      where: s.user_id == ^user_id,
      preload: [:feed],
      order_by: [asc: s.folder, asc: s.display_name]
    )
    |> Repo.all()
  end

  @doc """
  Updates a subscription.
  """
  def update_subscription(%Subscription{} = subscription, attrs) do
    subscription
    |> Subscription.changeset(attrs)
    |> Repo.update()
  end

  ## Items

  @doc """
  Creates or updates an item for a feed.
  Uses guid to detect duplicates.
  """
  def upsert_item(feed_id, attrs) do
    guid = attrs[:guid] || attrs["guid"]

    case Repo.get_by(Item, feed_id: feed_id, guid: guid) do
      nil ->
        %Item{}
        |> Item.changeset(Map.put(attrs, :feed_id, feed_id))
        |> Repo.insert()

      item ->
        # Only update if content might have changed
        item
        |> Item.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Gets items for a feed.
  """
  def list_feed_items(feed_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(i in Item,
      where: i.feed_id == ^feed_id,
      order_by: [desc: i.published_at, desc: i.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Gets items for all feeds a user is subscribed to.
  Only returns items from subscriptions where show_in_timeline is true.
  """
  def list_user_items(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    from(i in Item,
      join: s in Subscription,
      on: s.feed_id == i.feed_id and s.user_id == ^user_id and s.show_in_timeline == true,
      order_by: [desc: i.published_at, desc: i.inserted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [feed: []]
    )
    |> Repo.all()
  end

  @doc """
  Gets items for display in timeline, with feed info.
  Returns items as a list of maps suitable for timeline display.
  """
  def get_timeline_items(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    before = Keyword.get(opts, :before)

    query =
      from(i in Item,
        join: s in Subscription,
        on: s.feed_id == i.feed_id and s.user_id == ^user_id and s.show_in_timeline == true,
        join: f in Feed,
        on: f.id == i.feed_id,
        order_by: [desc: i.published_at, desc: i.inserted_at],
        limit: ^limit,
        select: %{
          id: i.id,
          type: :rss_item,
          title: i.title,
          content: i.content,
          summary: i.summary,
          url: i.url,
          author: i.author,
          published_at: i.published_at,
          inserted_at: i.inserted_at,
          image_url: i.image_url,
          enclosure_url: i.enclosure_url,
          enclosure_type: i.enclosure_type,
          categories: i.categories,
          feed_id: f.id,
          feed_title: f.title,
          feed_url: f.url,
          feed_favicon_url: f.favicon_url,
          feed_site_url: f.site_url
        }
      )

    query =
      if before do
        where(query, [i], i.published_at < ^before or i.inserted_at < ^before)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Counts total items for a user's subscriptions.
  """
  def count_user_items(user_id) do
    from(i in Item,
      join: s in Subscription,
      on: s.feed_id == i.feed_id and s.user_id == ^user_id,
      select: count(i.id)
    )
    |> Repo.one()
  end

  ## Helpers

  defp normalize_url(url) do
    url
    |> String.trim()
    |> URI.parse()
    |> then(fn uri ->
      # Ensure scheme
      uri =
        if uri.scheme do
          uri
        else
          %{uri | scheme: "https"}
        end

      # Build normalized URL
      URI.to_string(uri)
    end)
  end
end
