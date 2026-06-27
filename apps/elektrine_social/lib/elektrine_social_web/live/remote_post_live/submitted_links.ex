defmodule ElektrineSocialWeb.RemotePostLive.SubmittedLinks do
  @moduledoc false

  def message_submitted_link(msg) do
    metadata = map_get_value(msg, "media_metadata") || %{}
    link_preview_url = message_link_preview_url(msg)
    message_id = map_get_value(msg, "activitypub_id")
    message_url = map_get_value(msg, "activitypub_url")

    [
      map_get_value(msg, "primary_url"),
      metadata["external_link"],
      metadata["url"],
      metadata["source_url"],
      metadata["canonical_url"],
      metadata["link_url"],
      metadata["link"],
      link_preview_url,
      extract_http_url_from_content(map_get_value(msg, "content"))
    ]
    |> Enum.map(&normalize_http_url/1)
    |> Enum.find(fn url ->
      is_binary(url) && !same_activitypub_object_url?(url, message_id) &&
        !same_activitypub_object_url?(url, message_url)
    end)
  end

  def detect_submitted_url(post, local_message, remote_actor_domain)
      when is_map(post) do
    post_id = map_get_value(post, "id")

    [
      extract_attachment_submitted_link(map_get_value(post, "attachment")),
      extract_source_submitted_link(map_get_value(post, "source")),
      extract_url_field_submitted_link(map_get_value(post, "url"), post_id, remote_actor_domain),
      if(local_message, do: message_submitted_link(local_message), else: nil),
      extract_http_url_from_content(map_get_value(post, "content"))
    ]
    |> Enum.map(&normalize_http_url/1)
    |> Enum.find(&valid_submitted_url?(&1, post_id))
  end

  def detect_submitted_url(nil, local_message, _remote_actor_domain)
      when is_map(local_message) do
    message_submitted_link(local_message)
  end

  def detect_submitted_url(_, _, _), do: nil

  def normalize_http_url(url) when is_binary(url) do
    trimmed =
      url
      |> String.trim()
      |> then(&Regex.replace(~r/[\)\]\}\.,!?;:]+$/u, &1, ""))

    if String.starts_with?(trimmed, ["http://", "https://"]) do
      trimmed
    else
      nil
    end
  end

  def normalize_http_url(_), do: nil

  def extract_youtube_id(url) when is_binary(url) do
    patterns = [
      ~r/(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/)([a-zA-Z0-9_-]{11})/,
      ~r/youtube\.com\/watch\?.*v=([a-zA-Z0-9_-]{11})/
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, url) do
        [_, video_id] -> video_id
        _ -> nil
      end
    end)
  end

  def extract_youtube_id(_), do: nil

  def submitted_url_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  def submitted_url_host(_), do: nil

  defp message_link_preview_url(%{
         link_preview: %Elektrine.Social.LinkPreview{status: "success", url: url}
       })
       when is_binary(url),
       do: url

  defp message_link_preview_url(%{
         "link_preview" => %Elektrine.Social.LinkPreview{status: "success", url: url}
       })
       when is_binary(url),
       do: url

  defp message_link_preview_url(_), do: nil

  defp valid_submitted_url?(url, post_id) when is_binary(url) do
    String.starts_with?(url, ["http://", "https://"]) &&
      !same_activitypub_object_url?(url, post_id)
  end

  defp valid_submitted_url?(_, _), do: false

  defp extract_attachment_submitted_link(attachments) do
    attachments
    |> normalize_attachment_list()
    |> Enum.find_value(fn attachment ->
      type = map_get_value(attachment, "type")
      media_type = map_get_value(attachment, "mediaType")
      attachment_url = attachment_url(attachment)

      cond do
        !is_binary(attachment_url) ->
          nil

        type == "Link" ->
          attachment_url

        is_binary(media_type) && String.starts_with?(String.downcase(media_type), "text/html") ->
          attachment_url

        true ->
          nil
      end
    end)
  end

  defp extract_source_submitted_link(source) when is_map(source) do
    [map_get_value(source, "url"), map_get_value(source, "href")]
    |> Enum.map(&normalize_http_url/1)
    |> Enum.find(&is_binary/1)
  end

  defp extract_source_submitted_link(_), do: nil

  defp extract_url_field_submitted_link(url_field, post_id, remote_actor_domain) do
    urls =
      url_field
      |> url_candidates_from_field()
      |> Enum.map(&normalize_http_url/1)
      |> Enum.filter(fn url -> is_binary(url) && url != post_id end)

    Enum.find(urls, fn url ->
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) and is_binary(remote_actor_domain) ->
          host != remote_actor_domain

        _ ->
          false
      end
    end) || List.first(urls)
  end

  defp extract_http_url_from_content(content) when is_binary(content) do
    with [_, href] <- Regex.run(~r/href=["']([^"']+)["']/i, content),
         normalized when is_binary(normalized) <- normalize_http_url(href) do
      normalized
    else
      _ ->
        case Regex.run(~r/https?:\/\/[^\s<>"']+/i, content) do
          [url] -> normalize_http_url(url)
          _ -> nil
        end
    end
  end

  defp extract_http_url_from_content(_), do: nil

  defp same_activitypub_object_url?(url, other_url)
       when is_binary(url) and is_binary(other_url) do
    normalized_url = normalize_http_url(url)
    normalized_other_url = normalize_http_url(other_url)

    cond do
      !is_binary(normalized_url) || !is_binary(normalized_other_url) ->
        false

      normalized_url == normalized_other_url ->
        true

      true ->
        same_status_permalink?(normalized_url, normalized_other_url)
    end
  end

  defp same_activitypub_object_url?(_, _), do: false

  defp same_status_permalink?(url, other_url) do
    with %URI{host: host} = uri when is_binary(host) <- URI.parse(url),
         %URI{host: ^host} = other_uri <- URI.parse(other_url),
         segment when is_binary(segment) <- terminal_path_segment(uri.path),
         ^segment <- terminal_path_segment(other_uri.path) do
      status_permalink_path?(uri.path) || status_permalink_path?(other_uri.path)
    else
      _ -> false
    end
  end

  defp terminal_path_segment(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> List.last()
  end

  defp terminal_path_segment(_), do: nil

  defp status_permalink_path?(path) when is_binary(path) do
    segments = String.split(path, "/", trim: true)

    Enum.any?(segments, &(&1 == "statuses")) ||
      Enum.any?(segments, &String.starts_with?(&1, "@"))
  end

  defp normalize_attachment_list(nil), do: []
  defp normalize_attachment_list(attachments) when is_list(attachments), do: attachments
  defp normalize_attachment_list(attachment) when is_map(attachment), do: [attachment]
  defp normalize_attachment_list(_), do: []

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

  defp map_get_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, remote_post_atom_key(key))
    end
  end

  defp map_get_value(_, _), do: nil

  defp remote_post_atom_key("id"), do: :id
  defp remote_post_atom_key("_submitted_url"), do: :_submitted_url
  defp remote_post_atom_key("_youtube_id"), do: :_youtube_id
  defp remote_post_atom_key("_link_preview"), do: :_link_preview
  defp remote_post_atom_key("activitypub_id"), do: :activitypub_id
  defp remote_post_atom_key("activitypub_url"), do: :activitypub_url
  defp remote_post_atom_key("primary_url"), do: :primary_url
  defp remote_post_atom_key("source"), do: :source
  defp remote_post_atom_key("url"), do: :url
  defp remote_post_atom_key("type"), do: :type
  defp remote_post_atom_key("mediaType"), do: :mediaType
  defp remote_post_atom_key("href"), do: :href
  defp remote_post_atom_key("attachment"), do: :attachment
  defp remote_post_atom_key("media_metadata"), do: :media_metadata
  defp remote_post_atom_key("content"), do: :content
  defp remote_post_atom_key(_), do: nil
end
