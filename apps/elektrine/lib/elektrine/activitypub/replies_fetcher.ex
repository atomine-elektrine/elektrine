defmodule Elektrine.ActivityPub.RepliesFetcher do
  @moduledoc """
  Proactively fetches and stores replies from ActivityPub reply collections.

  When viewing a remote post, this module fetches the replies collection
  and stores replies locally, similar to how Akkoma handles reply fetching.
  This ensures replies are available even when the remote server's collection
  doesn't expose counts.
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{CollectionFetcher, Fetcher, Helpers}
  alias Elektrine.Messaging

  @max_replies 50
  @max_depth 3

  @doc """
  Fetches replies for a post and stores them locally.

  Called when viewing a remote post to ensure replies are available.
  Runs asynchronously to not block the page load.

  ## Parameters
  - `post_object` - The ActivityPub post object (must have "id" and optionally "replies")
  - `opts` - Options:
    - `:max_replies` - Maximum replies to fetch (default: #{@max_replies})
    - `:max_depth` - Maximum nesting depth to fetch (default: #{@max_depth})

  ## Returns
  - `{:ok, count}` - Number of replies stored
  - `{:error, reason}` - If fetching failed
  """
  def fetch_and_store_replies(post_object, opts \\ []) do
    max_replies = Keyword.get(opts, :max_replies, @max_replies)
    parent_ap_id = post_object["id"]
    replies_collection = post_object["replies"]

    # Get or create the parent message
    parent_message = Messaging.get_message_by_activitypub_id(parent_ap_id)

    if is_nil(parent_message) do
      Logger.debug("Parent message not found for #{parent_ap_id}, skipping reply fetch")
      {:error, :parent_not_found}
    else
      do_fetch_and_store_replies(replies_collection, parent_message.id, max_replies)
    end
  end

  @doc """
  Fetches replies for a message by its local ID.

  Useful when you have a message but need to refresh its replies.
  """
  def fetch_replies_for_message(message_id)
      when is_binary(message_id) or is_integer(message_id) do
    case Elektrine.Repo.get(Messaging.Message, message_id) do
      nil ->
        {:error, :message_not_found}

      message ->
        if message.activitypub_id do
          case Fetcher.fetch_object(message.activitypub_id) do
            {:ok, post_object} ->
              fetch_and_store_replies(post_object)

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :no_activitypub_id}
        end
    end
  end

  @doc """
  Fetches replies from a collection URL directly.

  Use this when you have the replies collection URL but not the full post object.
  """
  def fetch_from_collection_url(collection_url, parent_message_id, opts \\ [])
      when is_binary(collection_url) do
    max_replies = Keyword.get(opts, :max_replies, @max_replies)
    do_fetch_and_store_replies(collection_url, parent_message_id, max_replies)
  end

  # Private implementation

  defp do_fetch_and_store_replies(nil, _parent_message_id, _max_replies) do
    {:ok, 0}
  end

  defp do_fetch_and_store_replies(collection, parent_message_id, max_replies)
       when is_binary(collection) or is_map(collection) do
    case CollectionFetcher.fetch_collection(collection, max_items: max_replies) do
      {:ok, items} ->
        stored_count = process_reply_items(items, parent_message_id)
        Logger.debug("Stored #{stored_count} replies for message #{parent_message_id}")
        {:ok, stored_count}

      {:partial, items} ->
        stored_count = process_reply_items(items, parent_message_id)
        Logger.debug("Stored #{stored_count} partial replies for message #{parent_message_id}")
        {:ok, stored_count}

      {:error, reason} ->
        Logger.warning("Failed to fetch replies collection: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_reply_items(items, parent_message_id) do
    items
    |> Enum.map(&normalize_reply_item/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn item -> store_reply(item, parent_message_id) end)
    |> Enum.count(fn result -> result == :ok end)
  end

  # Normalize different reply item formats
  defp normalize_reply_item(item) when is_binary(item) do
    # Just a URL reference - need to fetch the full object
    case Fetcher.fetch_object(item) do
      {:ok, object} -> object
      {:error, _} -> nil
    end
  end

  defp normalize_reply_item(%{"type" => type} = item)
       when type in ["Note", "Article", "Page", "Question"] do
    item
  end

  defp normalize_reply_item(%{"object" => object}) when is_map(object) do
    # Wrapped in a Create activity
    normalize_reply_item(object)
  end

  defp normalize_reply_item(%{"object" => object_url}) when is_binary(object_url) do
    # Create activity with object URL
    case Fetcher.fetch_object(object_url) do
      {:ok, object} -> object
      {:error, _} -> nil
    end
  end

  defp normalize_reply_item(_), do: nil

  defp store_reply(object, parent_message_id) do
    actor_uri = object["attributedTo"] || object["actor"]

    if is_nil(actor_uri) do
      Logger.debug("Reply has no author, skipping: #{object["id"]}")
      :skip
    else
      case ActivityPub.get_or_fetch_actor(actor_uri) do
        {:ok, remote_actor} ->
          create_reply_message(object, remote_actor, parent_message_id)

        {:error, reason} ->
          Logger.debug("Failed to fetch actor #{actor_uri}: #{inspect(reason)}")
          :error
      end
    end
  rescue
    e ->
      Logger.warning("Error storing reply: #{inspect(e)}")
      :error
  end

  defp create_reply_message(object, remote_actor, parent_message_id) do
    # Check if already exists
    case Messaging.get_message_by_activitypub_id(object["id"]) do
      nil ->
        # Create new reply
        content = strip_html(object["content"] || "")
        visibility = determine_visibility(object)

        if visibility in ["public", "unlisted"] do
          {media_urls, alt_texts} = extract_media_with_alt_text(object)

          attrs = %{
            content: content,
            visibility: visibility,
            activitypub_id: object["id"],
            activitypub_url: object["url"] || object["id"],
            federated: true,
            remote_actor_id: remote_actor.id,
            reply_to_id: parent_message_id,
            media_urls: media_urls,
            media_metadata:
              if(map_size(alt_texts) > 0, do: %{"alt_texts" => alt_texts}, else: %{}),
            inserted_at: Helpers.parse_published_date(object["published"]),
            like_count: Helpers.extract_interaction_count(object, "likes"),
            reply_count: Helpers.extract_interaction_count(object, "replies"),
            share_count: Helpers.extract_interaction_count(object, "shares"),
            sensitive: object["sensitive"] || false,
            content_warning: object["summary"]
          }

          case Messaging.create_federated_message(attrs) do
            {:ok, _message} ->
              # Increment parent's reply count
              Elektrine.ActivityPub.SideEffects.increment_reply_count(parent_message_id)

              # Recursively fetch nested replies if they exist
              if object["replies"] do
                Task.start(fn ->
                  fetch_and_store_replies(object, max_replies: 10, max_depth: 2)
                end)
              end

              :ok

            {:error, %Ecto.Changeset{errors: [activitypub_id: {"has already been taken", _}]}} ->
              :already_exists

            {:error, reason} ->
              Logger.debug("Failed to create reply: #{inspect(reason)}")
              :error
          end
        else
          :skip
        end

      _existing ->
        :already_exists
    end
  end

  # Helper functions (simplified versions from CreateHandler)

  defp strip_html(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<p[^>]*>/, "\n")
    |> String.replace(~r/<\/p>/, "\n")
    |> String.replace(~r/<[^>]*>/, "")
    |> HtmlEntities.decode()
    |> String.trim()
  end

  defp determine_visibility(object) do
    to = object["to"] || []
    cc = object["cc"] || []
    public_address = "https://www.w3.org/ns/activitystreams#Public"

    cond do
      public_address in to -> "public"
      public_address in cc -> "unlisted"
      true -> "followers"
    end
  end

  defp extract_media_with_alt_text(object) do
    attachments = object["attachment"] || []

    attachments
    |> Enum.with_index()
    |> Enum.map(fn {attachment, idx} ->
      url =
        cond do
          is_binary(attachment["url"]) -> attachment["url"]
          is_map(attachment["url"]) -> attachment["url"]["href"]
          is_binary(attachment["href"]) -> attachment["href"]
          true -> nil
        end

      alt_text = attachment["name"] || attachment["summary"] || attachment["content"]
      {url, alt_text, idx}
    end)
    |> Enum.filter(fn {url, _alt, _idx} -> is_binary(url) && valid_media_url?(url) end)
    |> Enum.take(10)
    |> Enum.reduce({[], %{}}, fn {url, alt_text, idx}, {urls, alt_map} ->
      new_urls = urls ++ [url]

      new_alt_map =
        if alt_text && String.trim(alt_text) != "" do
          Map.put(alt_map, to_string(idx), String.trim(alt_text))
        else
          alt_map
        end

      {new_urls, new_alt_map}
    end)
  end

  defp valid_media_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["https", "http"] && uri.host != nil
  end

  defp valid_media_url?(_), do: false
end
