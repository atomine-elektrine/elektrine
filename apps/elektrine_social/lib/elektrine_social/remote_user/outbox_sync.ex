defmodule ElektrineSocial.RemoteUser.OutboxSync do
  @moduledoc false

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.Repo

  def sync_actor_outbox(actor_or_id, limit \\ 20)

  def sync_actor_outbox(actor_id, limit) when is_integer(actor_id) do
    case Repo.get(Actor, actor_id) do
      nil -> {:error, :actor_not_found}
      remote_actor -> sync_actor_outbox(remote_actor, limit)
    end
  end

  def sync_actor_outbox(%Actor{} = remote_actor, limit) do
    case ActivityPub.fetch_remote_user_timeline(remote_actor.id, limit: limit) do
      {:ok, outbox_posts} ->
        stored_posts = store_outbox_posts(outbox_posts, remote_actor)

        Enum.each(outbox_posts, &Elektrine.Messaging.SyncRemoteCountsWorker.enqueue/1)

        stored_posts
        |> Enum.filter(&((&1.reply_count || 0) > 0))
        |> Enum.each(fn message ->
          _ = Elektrine.ActivityPub.RepliesIngestWorker.enqueue(message.id)
        end)

        {:ok, stored_posts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def store_outbox_posts(outbox_posts, remote_actor) when is_list(outbox_posts) do
    outbox_posts
    |> Enum.map(fn post ->
      case post["id"] do
        activitypub_id when is_binary(activitypub_id) and activitypub_id != "" ->
          case Messaging.get_message_by_activitypub_id(activitypub_id) do
            nil -> create_outbox_post(post, remote_actor)
            existing -> refresh_existing_outbox_post(existing, post, remote_actor)
          end

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp create_outbox_post(post, remote_actor) do
    author_uri = post["attributedTo"] || remote_actor.uri

    author_actor =
      case ActivityPub.get_or_fetch_actor(author_uri) do
        {:ok, actor} -> actor
        _ -> nil
      end

    if author_actor do
      title = normalize_remote_post_title(post)
      content = post["content"] || title || ""
      {media_urls, alt_texts} = extract_media_from_post(post)
      like_count = extract_count_from_collection(post["likes"])

      reply_count =
        [
          extract_count_from_collection(post["replies"]),
          extract_count_from_collection(post["comments"]),
          parse_non_negative_count(post["repliesCount"])
        ]
        |> Enum.max(fn -> 0 end)

      share_count = extract_count_from_collection(post["shares"])
      metadata = build_outbox_metadata(post, alt_texts, remote_actor)

      inserted_at =
        case post["published"] do
          date when is_binary(date) ->
            case DateTime.from_iso8601(date) do
              {:ok, dt, _} -> DateTime.to_naive(dt)
              _ -> NaiveDateTime.utc_now()
            end

          _ ->
            NaiveDateTime.utc_now()
        end

      case Messaging.create_federated_message(%{
             content: content,
             title: title,
             visibility: "public",
             activitypub_id: post["id"],
             activitypub_url: post["url"] || post["id"],
             federated: true,
             remote_actor_id: author_actor.id,
             media_urls: media_urls,
             media_metadata: metadata,
             inserted_at: inserted_at,
             like_count: like_count,
             reply_count: reply_count,
             share_count: share_count
           }) do
        {:ok, message} ->
          _ = Elektrine.ActivityPub.CollectionCountSyncWorker.enqueue(message.id, post)
          Repo.preload(message, MessagingMessages.timeline_post_preloads())

        {:error, _} ->
          nil
      end
    end
  end

  defp refresh_existing_outbox_post(existing, post, remote_actor) do
    title = normalize_remote_post_title(post)
    content = post["content"] || title || ""
    {media_urls, alt_texts} = extract_media_from_post(post)

    metadata =
      build_outbox_metadata(post, alt_texts, remote_actor, existing.media_metadata || %{})

    like_count = extract_count_from_collection(post["likes"])

    reply_count =
      [
        extract_count_from_collection(post["replies"]),
        extract_count_from_collection(post["comments"]),
        parse_non_negative_count(post["repliesCount"])
      ]
      |> Enum.max(fn -> 0 end)

    share_count = extract_count_from_collection(post["shares"])

    updates =
      %{}
      |> maybe_put_if_blank(:title, existing.title, title)
      |> maybe_put_if_blank(:content, existing.content, content)
      |> maybe_put_if_empty_list(:media_urls, existing.media_urls || [], media_urls)
      |> maybe_put_if_blank(:activitypub_url, existing.activitypub_url, post["url"] || post["id"])
      |> maybe_put_if_changed(:media_metadata, existing.media_metadata || %{}, metadata)
      |> maybe_put_if_greater(:like_count, existing.like_count || 0, like_count)
      |> maybe_put_if_greater(:reply_count, existing.reply_count || 0, reply_count)
      |> maybe_put_if_greater(:share_count, existing.share_count || 0, share_count)

    if map_size(updates) > 0 do
      case existing
           |> Elektrine.Messaging.Message.federated_changeset(updates)
           |> Repo.update() do
        {:ok, message} -> Repo.preload(message, MessagingMessages.timeline_post_preloads())
        {:error, _} -> nil
      end
    end
  end

  defp normalize_remote_post_title(post) when is_map(post) do
    [post["name"], post["title"]]
    |> Enum.find_value(fn
      title when is_binary(title) ->
        case String.trim(title) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end)
  end

  defp normalize_remote_post_title(_), do: nil

  defp extract_media_from_post(post) do
    attachments = post["attachment"] || post["image"] || []
    attachments = if is_list(attachments), do: attachments, else: [attachments]

    Enum.reduce(attachments, {[], %{}}, fn attachment, {urls_acc, alt_acc} ->
      url =
        cond do
          is_binary(attachment) -> attachment
          is_map(attachment) && is_binary(attachment["url"]) -> attachment["url"]
          is_map(attachment) && is_map(attachment["url"]) -> attachment["url"]["href"]
          true -> nil
        end

      alt = if is_map(attachment), do: attachment["name"] || attachment["summary"], else: nil

      if url do
        new_alts = if alt, do: Map.put(alt_acc, url, alt), else: alt_acc
        {urls_acc ++ [url], new_alts}
      else
        {urls_acc, alt_acc}
      end
    end)
    |> then(fn {urls, alt_texts} -> {urls, %{"alt_texts" => alt_texts}} end)
  end

  defp build_outbox_metadata(post, alt_texts, remote_actor, base_metadata \\ %{}) do
    base_metadata
    |> maybe_put_metadata_field("type", post["type"])
    |> maybe_put_metadata_field("url", post["url"])
    |> maybe_put_metadata_field("sensitive", post["sensitive"])
    |> maybe_put_metadata_field("quoteUrl", post["quoteUrl"] || post["_misskey_quote"])
    |> maybe_put_metadata_field("replies", post["replies"])
    |> maybe_put_metadata_field("comments", post["comments"])
    |> maybe_put_metadata_field("likes", post["likes"])
    |> maybe_put_metadata_field("shares", post["shares"])
    |> maybe_put_community_actor_uri(remote_actor)
    |> Map.merge(alt_texts)
  end

  defp maybe_put_metadata_field(metadata, _key, nil), do: metadata

  defp maybe_put_metadata_field(metadata, key, value) when is_binary(value) and value != "",
    do: Map.put(metadata, key, value)

  defp maybe_put_metadata_field(metadata, key, value), do: Map.put(metadata, key, value)

  defp maybe_put_community_actor_uri(metadata, %{actor_type: "Group", uri: uri})
       when is_binary(uri), do: Map.put(metadata, "community_actor_uri", uri)

  defp maybe_put_community_actor_uri(metadata, _), do: metadata

  defp maybe_put_if_blank(updates, field, current, candidate) do
    current_blank? = not (is_binary(current) and String.trim(current) != "")
    candidate_present? = is_binary(candidate) and String.trim(candidate) != ""

    if current_blank? and candidate_present?,
      do: Map.put(updates, field, candidate),
      else: updates
  end

  defp maybe_put_if_empty_list(updates, _field, current, _candidate)
       when is_list(current) and current != [], do: updates

  defp maybe_put_if_empty_list(updates, field, _current, candidate)
       when is_list(candidate) and candidate != [], do: Map.put(updates, field, candidate)

  defp maybe_put_if_empty_list(updates, _field, _current, _candidate), do: updates

  defp maybe_put_if_changed(updates, field, current, candidate),
    do: if(candidate != current, do: Map.put(updates, field, candidate), else: updates)

  defp maybe_put_if_greater(updates, field, current, candidate)
       when is_integer(candidate) and candidate > current, do: Map.put(updates, field, candidate)

  defp maybe_put_if_greater(updates, _field, _current, _candidate), do: updates

  defp extract_count_from_collection(nil), do: 0

  defp extract_count_from_collection(collection) when is_map(collection),
    do: parse_non_negative_count(collection["totalItems"])

  defp extract_count_from_collection(collection) when is_integer(collection), do: collection

  defp extract_count_from_collection(collection) when is_binary(collection),
    do: parse_non_negative_count(collection)

  defp extract_count_from_collection(_), do: 0

  defp parse_non_negative_count(value) when is_integer(value), do: max(value, 0)

  defp parse_non_negative_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp parse_non_negative_count(_), do: 0
end
