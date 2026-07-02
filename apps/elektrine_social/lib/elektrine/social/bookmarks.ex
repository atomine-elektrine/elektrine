defmodule Elektrine.Social.Bookmarks do
  @moduledoc """
  Handles saved items (bookmarks) for posts and RSS items.

  This module provides functionality for users to save content for later reading,
  including both timeline posts and RSS feed items.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Social.BookmarkFolders
  alias Elektrine.Social.Message
  alias Elektrine.Social.MessagePolicy
  alias Elektrine.Social.SavedItem

  @doc """
  Saves a post (message) for later.

  ## Examples

      iex> save_post(user_id, message_id)
      {:ok, %SavedItem{}}
      
      iex> save_post(user_id, already_saved_id)
      {:ok, %SavedItem{}}
  """
  def save_post(user_id, message_id, opts \\ []) do
    folder_id = Keyword.get(opts, :bookmark_folder_id) || Keyword.get(opts, :folder_id)

    with %Message{} = message <- Repo.get(Message, message_id),
         true <- MessagePolicy.save?(user_id, message),
         true <- BookmarkFolders.folder_belongs_to_user?(folder_id, user_id) do
      case Repo.get_by(SavedItem, user_id: user_id, message_id: message_id) do
        %SavedItem{} = saved ->
          maybe_update_folder(saved, folder_id)

        nil ->
          insert_saved_message(user_id, message_id, folder_id)
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_authorized}
    end
  end

  defp insert_saved_message(user_id, message_id, folder_id) do
    %SavedItem{}
    |> SavedItem.message_changeset(%{
      user_id: user_id,
      message_id: message_id,
      bookmark_folder_id: normalize_folder_id(folder_id)
    })
    |> Repo.insert()
    |> case do
      {:error, %Ecto.Changeset{}} = error ->
        case Repo.get_by(SavedItem, user_id: user_id, message_id: message_id) do
          %SavedItem{} = saved -> maybe_update_folder(saved, folder_id)
          nil -> error
        end

      result ->
        result
    end
  end

  @doc """
  Saves an RSS item for later.
  """
  def save_rss_item(user_id, rss_item_id, opts \\ []) do
    folder_id = Keyword.get(opts, :bookmark_folder_id) || Keyword.get(opts, :folder_id)

    if BookmarkFolders.folder_belongs_to_user?(folder_id, user_id) do
      do_save_rss_item(user_id, rss_item_id, folder_id)
    else
      {:error, :not_authorized}
    end
  end

  defp do_save_rss_item(user_id, rss_item_id, folder_id) do
    case Repo.get_by(SavedItem, user_id: user_id, rss_item_id: rss_item_id) do
      %SavedItem{} = saved ->
        maybe_update_folder(saved, folder_id)

      nil ->
        insert_saved_rss_item(user_id, rss_item_id, folder_id)
    end
  end

  defp insert_saved_rss_item(user_id, rss_item_id, folder_id) do
    %SavedItem{}
    |> SavedItem.rss_item_changeset(%{
      user_id: user_id,
      rss_item_id: rss_item_id,
      bookmark_folder_id: normalize_folder_id(folder_id)
    })
    |> Repo.insert()
    |> case do
      {:error, %Ecto.Changeset{}} = error ->
        case Repo.get_by(SavedItem, user_id: user_id, rss_item_id: rss_item_id) do
          %SavedItem{} = saved -> maybe_update_folder(saved, folder_id)
          nil -> error
        end

      result ->
        result
    end
  end

  @doc """
  Unsaves a post.

  Returns `{:ok, saved_item}` if the post was saved and is now removed,
  or `{:ok, nil}` if the post was already unsaved.
  """
  def unsave_post(user_id, message_id) do
    case Repo.get_by(SavedItem, user_id: user_id, message_id: message_id) do
      nil -> {:ok, nil}
      saved -> Repo.delete(saved)
    end
  end

  @doc """
  Unsaves an RSS item.
  """
  def unsave_rss_item(user_id, rss_item_id) do
    case Repo.get_by(SavedItem, user_id: user_id, rss_item_id: rss_item_id) do
      nil -> {:ok, nil}
      saved -> Repo.delete(saved)
    end
  end

  @doc """
  Checks if user has saved a post.
  """
  def post_saved?(user_id, message_id) do
    Repo.exists?(
      from s in SavedItem,
        where: s.user_id == ^user_id and s.message_id == ^message_id
    )
  end

  @doc """
  Checks if user has saved an RSS item.
  """
  def rss_item_saved?(user_id, rss_item_id) do
    Repo.exists?(
      from s in SavedItem,
        where: s.user_id == ^user_id and s.rss_item_id == ^rss_item_id
    )
  end

  @doc """
  Returns a MapSet of message IDs that the user has saved from the given list.

  Useful for efficiently checking multiple posts at once, e.g., when rendering a timeline.
  """
  def list_user_saved_posts(user_id, message_ids) when is_list(message_ids) do
    from(s in SavedItem,
      where: s.user_id == ^user_id and s.message_id in ^message_ids,
      select: s.message_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns a MapSet of RSS item IDs that the user has saved from the given list.
  """
  def list_user_saved_rss_items(user_id, rss_item_ids) when is_list(rss_item_ids) do
    from(s in SavedItem,
      where: s.user_id == ^user_id and s.rss_item_id in ^rss_item_ids,
      select: s.rss_item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Gets all saved posts for a user, newest first.

  Returns messages preloaded with sender, conversation, link_preview.

  ## Options

    * `:limit` - Maximum number of posts to return (default: 20)
    * `:offset` - Number of posts to skip (default: 0)
  """
  def get_saved_posts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    search_query = Keyword.get(opts, :search_query)
    folder_id = Keyword.get(opts, :bookmark_folder_id) || Keyword.get(opts, :folder_id)
    before_id = Keyword.get(opts, :before_id)
    since_id = Keyword.get(opts, :since_id)
    min_id = Keyword.get(opts, :min_id)

    # First get the message IDs in saved order
    message_ids_query =
      from(s in SavedItem,
        where: s.user_id == ^user_id and not is_nil(s.message_id),
        join: m in Message,
        on: m.id == s.message_id,
        left_join: sender in assoc(m, :sender),
        left_join: remote_actor in assoc(m, :remote_actor),
        where: is_nil(m.deleted_at),
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        offset: ^offset,
        select: {m.id, s.inserted_at}
      )

    message_ids_query =
      if is_nil(folder_id) do
        message_ids_query
      else
        from(s in message_ids_query, where: s.bookmark_folder_id == ^folder_id)
      end

    message_ids_query =
      message_ids_query
      |> maybe_filter_before_id(before_id)
      |> maybe_filter_since_id(since_id)
      |> maybe_filter_since_id(min_id)

    message_ids_query =
      if Elektrine.Strings.present?(search_query) do
        pattern = "%" <> search_query <> "%"

        from([s, m, sender, remote_actor] in message_ids_query,
          where:
            ilike(m.content, ^pattern) or
              (not is_nil(m.title) and ilike(m.title, ^pattern)) or
              (not is_nil(sender.username) and ilike(sender.username, ^pattern)) or
              (not is_nil(sender.display_name) and ilike(sender.display_name, ^pattern)) or
              (not is_nil(remote_actor.username) and ilike(remote_actor.username, ^pattern)) or
              (not is_nil(remote_actor.display_name) and
                 ilike(remote_actor.display_name, ^pattern)) or
              (not is_nil(remote_actor.domain) and ilike(remote_actor.domain, ^pattern))
        )
      else
        message_ids_query
      end

    # Get the IDs and their order
    id_order_pairs = Repo.all(message_ids_query)
    message_ids = Enum.map(id_order_pairs, fn {id, _} -> id end)

    if message_ids == [] do
      []
    else
      # Fetch the messages with preloads
      messages =
        from(m in Message,
          where: m.id in ^message_ids,
          preload: [
            sender: [:profile],
            conversation: [],
            link_preview: [],
            hashtags: [],
            remote_actor: []
          ]
        )
        |> Repo.all()

      # Re-order by saved order
      id_to_order =
        id_order_pairs
        |> Enum.with_index()
        |> Enum.into(%{}, fn {{id, _}, idx} -> {id, idx} end)

      Enum.sort_by(messages, fn m -> Map.get(id_to_order, m.id, 999_999) end)
    end
  end

  @doc """
  Gets all saved RSS items for a user, newest first.

  Returns RSS items formatted for timeline display.

  ## Options

    * `:limit` - Maximum number of items to return (default: 20)
    * `:offset` - Number of items to skip (default: 0)
  """
  def get_saved_rss_items(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    folder_id = Keyword.get(opts, :bookmark_folder_id) || Keyword.get(opts, :folder_id)

    alias Elektrine.RSS.{Feed, Item}

    query =
      from(s in SavedItem,
        where: s.user_id == ^user_id and not is_nil(s.rss_item_id),
        join: i in Item,
        on: i.id == s.rss_item_id,
        join: f in Feed,
        on: f.id == i.feed_id,
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        offset: ^offset,
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
      if is_nil(folder_id) do
        query
      else
        from(s in query, where: s.bookmark_folder_id == ^folder_id)
      end

    query
    |> Repo.all()
  end

  @doc """
  Gets count of saved posts for a user.
  """
  def count_saved_posts(user_id) do
    from(s in SavedItem,
      where: s.user_id == ^user_id and not is_nil(s.message_id),
      select: count(s.id)
    )
    |> Repo.one()
  end

  defp maybe_update_folder(%SavedItem{} = saved, nil), do: {:ok, saved}
  defp maybe_update_folder(%SavedItem{} = saved, ""), do: {:ok, saved}

  defp maybe_update_folder(%SavedItem{} = saved, folder_id) do
    saved
    |> Ecto.Changeset.change(bookmark_folder_id: normalize_folder_id(folder_id))
    |> Repo.update()
  end

  defp normalize_folder_id(nil), do: nil
  defp normalize_folder_id(""), do: nil
  defp normalize_folder_id(folder_id), do: folder_id

  defp maybe_filter_before_id(query, id) when is_integer(id) do
    from([_s, m, _sender, _remote_actor] in query, where: m.id < ^id)
  end

  defp maybe_filter_before_id(query, _id), do: query

  defp maybe_filter_since_id(query, id) when is_integer(id) do
    from([_s, m, _sender, _remote_actor] in query, where: m.id > ^id)
  end

  defp maybe_filter_since_id(query, _id), do: query
end
