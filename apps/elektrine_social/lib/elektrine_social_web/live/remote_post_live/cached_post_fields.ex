defmodule ElektrineSocialWeb.RemotePostLive.CachedPostFields do
  @moduledoc false

  alias ElektrineSocialWeb.RemotePostLive.Counts

  def cached_remote_status_fields(metadata) when is_map(metadata) do
    metadata
    |> Map.take([
      "emoji_reactions",
      "quotes_count",
      "quote",
      "quote_id",
      "quote_url",
      "card",
      "application",
      "language",
      "media_attachments",
      "pleroma",
      "misskey"
    ])
  end

  def cached_remote_status_fields(_), do: %{}

  def cached_message_attachments(msg) do
    metadata = msg.media_metadata || %{}

    media_url_attachments =
      (msg.media_urls || [])
      |> Enum.map(fn url ->
        full_url = message_attachment_url(url, msg)

        if Elektrine.Strings.present?(full_url) do
          attachment_type = media_attachment_type(full_url, metadata)

          %{
            "type" => attachment_type,
            "url" => full_url,
            "mediaType" => default_media_type(attachment_type)
          }
        end
      end)

    metadata_attachments =
      [
        field_value(metadata, ["attachment", :attachment]),
        field_value(metadata, ["attachments", :attachments]),
        field_value(metadata, ["media_attachments", :media_attachments])
      ]
      |> Enum.flat_map(&normalize_attachment_list/1)
      |> Enum.map(&normalize_cached_attachment/1)

    (metadata_attachments ++ media_url_attachments)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&attachment_url/1)
  end

  def message_attachment_url(url, %{federated: true}) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]),
      do: url,
      else: Elektrine.Uploads.attachment_url(url)
  end

  def message_attachment_url(url, message), do: Elektrine.Uploads.attachment_url(url, message)

  def normalize_attachment_list(nil), do: []
  def normalize_attachment_list(attachments) when is_list(attachments), do: attachments
  def normalize_attachment_list(attachment) when is_map(attachment), do: [attachment]
  def normalize_attachment_list(_), do: []

  def map_get_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        existing_atom_map_value(map, key)
    end
  end

  def map_get_value(_, _), do: nil

  def maybe_preserve_cached_post_fields(post_object, existing_post) do
    post_object
    |> maybe_put_field_from_existing(existing_post, "content")
    |> maybe_put_field_from_existing(existing_post, "name")
    |> maybe_put_field_from_existing(existing_post, "inReplyTo")
    |> maybe_put_field_from_existing(existing_post, "inReplyToAuthor")
    |> maybe_put_field_from_existing(existing_post, "inReplyToContent")
    |> maybe_put_field_from_existing(existing_post, "inReplyToTitle")
    |> maybe_put_non_empty_field_from_existing(existing_post, "attachment")
    |> maybe_put_non_empty_field_from_existing(existing_post, "sensitive")
    |> maybe_put_non_empty_field_from_existing(existing_post, "summary")
    |> maybe_preserve_higher_reply_count(existing_post)
  end

  defp normalize_cached_attachment(attachment) when is_map(attachment) do
    url =
      attachment_url(attachment) ||
        field_value(attachment, ["remote_url", :remote_url]) ||
        field_value(attachment, ["preview_url", :preview_url])

    if Elektrine.Strings.present?(url) do
      type =
        field_value(attachment, ["type", :type]) ||
          media_attachment_type(url)

      media_type =
        field_value(attachment, ["mediaType", :mediaType, "media_type", :media_type]) ||
          default_media_type(type)

      %{
        "type" => type,
        "url" => url,
        "mediaType" => media_type,
        "preview_url" => field_value(attachment, ["preview_url", :preview_url]),
        "width" => field_value(attachment, ["width", :width]),
        "height" => field_value(attachment, ["height", :height]),
        "duration" => field_value(attachment, ["duration", :duration]),
        "name" => field_value(attachment, ["name", :name, "description", :description])
      }
    end
  end

  defp normalize_cached_attachment(_), do: nil

  defp media_attachment_type(url, metadata \\ %{}) when is_binary(url) do
    cond do
      String.match?(url, ~r/\.(mp4|webm|ogv|mov)(\?.*)?$/i) -> "Video"
      String.match?(url, ~r/\.(mp3|wav|ogg|m4a|flac)(\?.*)?$/i) -> "Audio"
      video_object_metadata?(metadata) -> "Video"
      true -> "Image"
    end
  end

  defp video_object_metadata?(metadata) when is_map(metadata) do
    type = metadata |> field_value(["type", :type]) |> to_string() |> String.downcase()

    type == "video" ||
      metadata
      |> field_value(["media_attachments", :media_attachments, "attachments", :attachments])
      |> normalize_attachment_list()
      |> Enum.any?(fn attachment ->
        media_type = field_value(attachment, ["mediaType", :mediaType, "media_type", :media_type])

        attachment_type =
          attachment |> field_value(["type", :type]) |> to_string() |> String.downcase()

        attachment_type == "video" || video_media_type?(media_type)
      end)
  end

  defp video_object_metadata?(_), do: false

  defp video_media_type?(media_type) when is_binary(media_type) do
    media_type = String.downcase(media_type)

    String.starts_with?(media_type, "video/") ||
      media_type in ["application/x-mpegurl", "application/vnd.apple.mpegurl"]
  end

  defp video_media_type?(_), do: false

  defp default_media_type(type) when is_binary(type) do
    case String.downcase(type) do
      "video" -> "video/mp4"
      "audio" -> "audio/mpeg"
      _ -> "image/jpeg"
    end
  end

  defp default_media_type(_), do: "image/jpeg"

  defp url_candidates_from_field(nil), do: []
  defp url_candidates_from_field(url) when is_binary(url), do: [url]

  defp url_candidates_from_field(urls) when is_list(urls) do
    Enum.flat_map(urls, &url_candidates_from_field/1)
  end

  defp url_candidates_from_field(url_map) when is_map(url_map) do
    [
      map_get_value(url_map, "href"),
      map_get_value(url_map, "url"),
      map_get_value(url_map, "id")
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp url_candidates_from_field(_), do: []

  defp attachment_url(attachment) when is_map(attachment) do
    case map_get_value(attachment, "url") do
      url when is_binary(url) ->
        url

      url_map when is_map(url_map) ->
        map_get_value(url_map, "href") || map_get_value(url_map, "url")

      url_list when is_list(url_list) ->
        url_list
        |> Enum.flat_map(&url_candidates_from_field/1)
        |> List.first()

      _ ->
        map_get_value(attachment, "href")
    end
  end

  defp attachment_url(_), do: nil

  defp existing_atom_map_value(map, key) do
    Map.get(map, remote_post_atom_key(key))
  end

  defp remote_post_atom_key("id"), do: :id
  defp remote_post_atom_key("_local_message_id"), do: :_local_message_id
  defp remote_post_atom_key("_local_activitypub_id"), do: :_local_activitypub_id
  defp remote_post_atom_key("_lemmy"), do: :_lemmy
  defp remote_post_atom_key("attributedTo"), do: :attributedTo
  defp remote_post_atom_key("actor"), do: :actor
  defp remote_post_atom_key("_local_user"), do: :_local_user
  defp remote_post_atom_key("_local"), do: :_local
  defp remote_post_atom_key("content"), do: :content
  defp remote_post_atom_key("summary"), do: :summary
  defp remote_post_atom_key("published"), do: :published
  defp remote_post_atom_key("_submitted_url"), do: :_submitted_url
  defp remote_post_atom_key("_youtube_id"), do: :_youtube_id
  defp remote_post_atom_key("_link_preview"), do: :_link_preview
  defp remote_post_atom_key("upvotes"), do: :upvotes
  defp remote_post_atom_key("score"), do: :score
  defp remote_post_atom_key("_local_like_count"), do: :_local_like_count
  defp remote_post_atom_key("likes"), do: :likes
  defp remote_post_atom_key("shares"), do: :shares
  defp remote_post_atom_key("_local_share_count"), do: :_local_share_count
  defp remote_post_atom_key("child_count"), do: :child_count
  defp remote_post_atom_key("attachment"), do: :attachment
  defp remote_post_atom_key("media_metadata"), do: :media_metadata
  defp remote_post_atom_key("activitypub_id"), do: :activitypub_id
  defp remote_post_atom_key("activitypub_url"), do: :activitypub_url
  defp remote_post_atom_key("primary_url"), do: :primary_url
  defp remote_post_atom_key("source"), do: :source
  defp remote_post_atom_key("url"), do: :url
  defp remote_post_atom_key("type"), do: :type
  defp remote_post_atom_key("mediaType"), do: :mediaType
  defp remote_post_atom_key("href"), do: :href
  defp remote_post_atom_key("reply_count"), do: :reply_count
  defp remote_post_atom_key("repliesCount"), do: :repliesCount
  defp remote_post_atom_key("replies"), do: :replies
  defp remote_post_atom_key("comments"), do: :comments
  defp remote_post_atom_key("inReplyTo"), do: :inReplyTo
  defp remote_post_atom_key("in_reply_to"), do: :in_reply_to
  defp remote_post_atom_key("inReplyToContent"), do: :inReplyToContent
  defp remote_post_atom_key("inReplyToTitle"), do: :inReplyToTitle
  defp remote_post_atom_key("inReplyToAuthor"), do: :inReplyToAuthor
  defp remote_post_atom_key("name"), do: :name
  defp remote_post_atom_key("likesCount"), do: :likesCount
  defp remote_post_atom_key("sharesCount"), do: :sharesCount
  defp remote_post_atom_key("announcesCount"), do: :announcesCount
  defp remote_post_atom_key(_), do: nil

  defp maybe_put_field_from_existing(post_object, existing_post, key) do
    current = map_get_value(post_object, key)
    fallback = map_get_value(existing_post, key)

    if Elektrine.Strings.present?(current) do
      post_object
    else
      if Elektrine.Strings.present?(fallback) do
        Map.put(post_object, key, fallback)
      else
        post_object
      end
    end
  end

  defp maybe_put_non_empty_field_from_existing(post_object, existing_post, key) do
    current = map_get_value(post_object, key)
    fallback = map_get_value(existing_post, key)

    if non_empty_value?(current) || !non_empty_value?(fallback) do
      post_object
    else
      Map.put(post_object, key, fallback)
    end
  end

  defp non_empty_value?(value) when is_binary(value), do: Elektrine.Strings.present?(value)
  defp non_empty_value?(value) when is_list(value), do: value != []
  defp non_empty_value?(value) when is_map(value), do: map_size(value) > 0
  defp non_empty_value?(value), do: not is_nil(value) and value != false

  defp maybe_preserve_higher_reply_count(post_object, existing_post)
       when is_map(post_object) and is_map(existing_post) do
    current_count =
      [
        map_get_value(post_object, "reply_count"),
        map_get_value(post_object, "repliesCount"),
        Counts.total_items_from_collection(map_get_value(post_object, "replies")),
        Counts.total_items_from_collection(map_get_value(post_object, "comments"))
      ]
      |> Enum.map(&Counts.normalize_cached_reply_count/1)
      |> Enum.max(fn -> 0 end)

    fallback_count =
      [
        map_get_value(existing_post, "reply_count"),
        map_get_value(existing_post, "repliesCount"),
        Counts.total_items_from_collection(map_get_value(existing_post, "replies")),
        Counts.total_items_from_collection(map_get_value(existing_post, "comments"))
      ]
      |> Enum.map(&Counts.normalize_cached_reply_count/1)
      |> Enum.max(fn -> 0 end)

    if fallback_count > current_count do
      post_object
      |> Map.put("reply_count", fallback_count)
      |> Map.put("repliesCount", fallback_count)
      |> Map.put(
        "replies",
        Counts.put_collection_total(Map.get(post_object, "replies"), fallback_count)
      )
      |> Map.put(
        "comments",
        Counts.put_collection_total(Map.get(post_object, "comments"), fallback_count)
      )
    else
      post_object
    end
  end

  defp maybe_preserve_higher_reply_count(post_object, _), do: post_object

  defp field_value(nil, _keys), do: nil

  defp field_value(value, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> field_value(value, key) end)
  end

  defp field_value(%_{} = value, key) when is_atom(key), do: Map.get(value, key)
  defp field_value(%{} = value, key), do: Map.get(value, key)
  defp field_value(_, _), do: nil
end
