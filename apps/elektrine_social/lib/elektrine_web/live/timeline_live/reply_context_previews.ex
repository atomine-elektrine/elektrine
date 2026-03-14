defmodule ElektrineWeb.TimelineLive.ReplyContextPreviews do
  @moduledoc false

  alias Elektrine.ActivityPub.Fetcher
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message

  @default_limit 8

  def candidate_refs(posts, limit \\ @default_limit)

  def candidate_refs(posts, limit) when is_list(posts) do
    posts
    |> Enum.map(&candidate_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  def candidate_refs(_, _), do: []

  def fetch_previews(refs, fetch_fun \\ &Fetcher.fetch_object/1)

  def fetch_previews(refs, fetch_fun) when is_list(refs) do
    Enum.reduce(refs, %{}, fn ref, acc ->
      case preview_for_ref(ref, fetch_fun) do
        nil -> acc
        preview -> Map.put(acc, ref, preview)
      end
    end)
  end

  def fetch_previews(_, _), do: %{}

  def fetch_local_previews(refs) when is_list(refs) do
    fetch_previews(refs, fn _ref -> {:error, :remote_fetch_disabled} end)
  end

  def fetch_local_previews(_), do: %{}

  def apply_previews(posts, previews_by_ref) when is_list(posts) and is_map(previews_by_ref) do
    Enum.map(posts, &apply_preview(&1, previews_by_ref))
  end

  def apply_previews(posts, _), do: posts

  defp candidate_ref(post) when is_map(post) do
    ref = metadata_in_reply_to(post)

    if is_binary(ref) and ref != "" and not reply_preview_available?(post) do
      ref
    end
  end

  defp candidate_ref(_), do: nil

  defp reply_preview_available?(post) when is_map(post) do
    has_reply_to_content? =
      case Map.get(post, :reply_to) || Map.get(post, "reply_to") do
        %Ecto.Association.NotLoaded{} ->
          false

        reply_to when is_map(reply_to) ->
          present_binary?(Map.get(reply_to, :content) || Map.get(reply_to, "content"))

        _ ->
          false
      end

    has_reply_to_content? || present_binary?(metadata_in_reply_to_content(post))
  end

  defp reply_preview_available?(_), do: false

  defp preview_for_ref(ref, fetch_fun) when is_binary(ref) do
    case Messaging.get_message_by_activitypub_ref(ref) do
      %Message{} = message ->
        preview_from_message(message)

      _ ->
        case fetch_fun.(ref) do
          {:ok, object} when is_map(object) -> preview_from_object(object, ref)
          _ -> nil
        end
    end
  end

  defp preview_for_ref(_, _), do: nil

  defp preview_from_message(%Message{} = message) do
    metadata = message.media_metadata || %{}

    preview_map(
      message.content || metadata["inReplyToContent"] || metadata["in_reply_to_content"],
      metadata["inReplyToAuthor"] || metadata["in_reply_to_author"]
    )
  end

  defp preview_from_object(object, ref) when is_map(object) do
    author =
      object["attributedTo"] ||
        object["actor"] ||
        object["attributed_to"] ||
        extract_author_from_url(ref)

    preview_map(object["content"], normalize_author(author))
  end

  defp preview_map(content, author) do
    %{}
    |> maybe_put("inReplyToContent", normalize_preview_content(content))
    |> maybe_put("inReplyToAuthor", normalize_author(author))
    |> case do
      map when map_size(map) > 0 -> map
      _ -> nil
    end
  end

  defp apply_preview(post, previews_by_ref) when is_map(post) and is_map(previews_by_ref) do
    ref = metadata_in_reply_to(post)

    case Map.get(previews_by_ref, ref) do
      nil ->
        post

      preview ->
        metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}

        updated_metadata =
          Enum.reduce(preview, metadata, fn {key, value}, acc ->
            put_metadata_if_blank(acc, key, value)
          end)

        if updated_metadata == metadata do
          post
        else
          put_post_metadata(post, updated_metadata)
        end
    end
  end

  defp apply_preview(post, _), do: post

  defp put_post_metadata(%{media_metadata: _} = post, metadata),
    do: %{post | media_metadata: metadata}

  defp put_post_metadata(post, metadata) when is_map(post),
    do: Map.put(post, :media_metadata, metadata)

  defp put_post_metadata(post, _metadata), do: post

  defp put_metadata_if_blank(metadata, _key, nil), do: metadata

  defp put_metadata_if_blank(metadata, key, value) when is_binary(value) do
    if present_binary?(Map.get(metadata, key)) do
      metadata
    else
      Map.put(metadata, key, value)
    end
  end

  defp put_metadata_if_blank(metadata, key, value) do
    if Map.has_key?(metadata, key) do
      metadata
    else
      Map.put(metadata, key, value)
    end
  end

  defp metadata_in_reply_to(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata")

    if is_map(metadata) do
      [
        Map.get(metadata, "inReplyTo"),
        Map.get(metadata, "in_reply_to"),
        Map.get(metadata, :inReplyTo),
        Map.get(metadata, :in_reply_to)
      ]
      |> Enum.find_value(&normalize_ref/1)
    end
  end

  defp metadata_in_reply_to(_), do: nil

  defp metadata_in_reply_to_content(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata")

    if is_map(metadata) do
      metadata["inReplyToContent"] ||
        metadata["in_reply_to_content"] ||
        metadata[:inReplyToContent] ||
        metadata[:in_reply_to_content]
    end
  end

  defp metadata_in_reply_to_content(_), do: nil

  defp normalize_ref(%{"id" => id}), do: normalize_ref(id)
  defp normalize_ref(%{"href" => href}), do: normalize_ref(href)
  defp normalize_ref(%{id: id}), do: normalize_ref(id)
  defp normalize_ref(%{href: href}), do: normalize_ref(href)
  defp normalize_ref([first | _]), do: normalize_ref(first)

  defp normalize_ref(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_ref(_), do: nil

  defp normalize_preview_content(content) when is_binary(content) do
    case String.trim(content) do
      "" -> nil
      _ -> content
    end
  end

  defp normalize_preview_content(_), do: nil

  defp normalize_author(%{"id" => id}), do: normalize_author(id)
  defp normalize_author(%{"url" => url}), do: normalize_author(url)
  defp normalize_author(%{id: id}), do: normalize_author(id)
  defp normalize_author(%{url: url}), do: normalize_author(url)

  defp normalize_author(author) when is_binary(author) do
    author =
      if String.starts_with?(author, "http") do
        extract_author_from_url(author) || author
      else
        author
      end

    case String.trim(author) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_author(_), do: nil

  defp extract_author_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host, path: path} when is_binary(host) and is_binary(path) ->
        case extract_username_from_path(path) do
          username when is_binary(username) -> "@#{username}@#{host}"
          _ -> "a post on #{host}"
        end

      %{host: host} when is_binary(host) and host != "" ->
        "a post on #{host}"

      _ ->
        nil
    end
  end

  defp extract_author_from_url(_), do: nil

  defp extract_username_from_path(path) when is_binary(path) do
    case path_segments(path) do
      ["users", username | _] ->
        sanitize_identifier(username)

      ["u", username | _] ->
        sanitize_identifier(username)

      [segment | _] when is_binary(segment) ->
        if String.starts_with?(segment, "@") do
          segment |> String.trim_leading("@") |> sanitize_identifier()
        end

      _ ->
        nil
    end
  end

  defp extract_username_from_path(_), do: nil

  defp path_segments(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp sanitize_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("@")
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp sanitize_identifier(_), do: nil

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
