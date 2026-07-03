defmodule Elektrine.Social.MediaAttachments do
  @moduledoc """
  Post media attachment metadata: normalization, alt text, and focal point updates.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages, as: MessagingMessages

  @public_audience_uris ["Public", "as:Public", "https://www.w3.org/ns/activitystreams#Public"]

  def merge_post_media_metadata(
        base_metadata \\ %{},
        alt_texts \\ %{},
        community_actor_uri \\ nil
      )

  def merge_post_media_metadata(base_metadata, alt_texts, community_actor_uri) do
    base_metadata
    |> normalize_media_metadata()
    |> maybe_merge_attachment_alt_texts(alt_texts)
    |> maybe_put_alt_texts(alt_texts)
    |> maybe_put_community_actor_uri(community_actor_uri)
  end

  def update_media_attachment_metadata(user_id, media_id, attrs)
      when is_integer(user_id) and is_binary(media_id) and is_map(attrs) do
    normalized_media_id = normalize_media_attachment_lookup_id(media_id)

    with %Message{} = message <- get_owned_message_for_media(user_id, normalized_media_id),
         {:ok, metadata, attachment} <-
           put_media_attachment_metadata(message, normalized_media_id, attrs),
         {:ok, _updated_message} <-
           MessagingMessages.update_message_metadata(message, %{media_metadata: metadata}) do
      {:ok, attachment}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_media_attachment_metadata(_user_id, _media_id, _attrs), do: {:error, :not_found}

  defp get_owned_message_for_media(user_id, media_id) do
    metadata_match = %{"attachments" => [%{"id" => media_id}]}

    from(m in Message,
      where: m.sender_id == ^user_id,
      where: is_nil(m.deleted_at),
      where: fragment("? = ANY(?)", ^media_id, m.media_urls),
      or_where:
        m.sender_id == ^user_id and is_nil(m.deleted_at) and
          fragment("? @> ?", m.media_metadata, ^metadata_match),
      limit: 1
    )
    |> Repo.one()
  end

  defp put_media_attachment_metadata(%Message{} = message, media_id, attrs) do
    media_urls = message.media_urls || []
    metadata = normalize_media_metadata(message.media_metadata || %{})
    attachments = metadata |> Map.get("attachments", []) |> normalize_existing_media_attachments()

    with {:ok, index, url, attachment} <-
           find_media_attachment(media_urls, attachments, media_id),
         {:ok, updates} <- media_attachment_updates(attrs) do
      updated_attachment =
        attachment
        |> Map.put_new("id", media_attachment_id(url))
        |> Map.put("url", url)
        |> apply_media_attachment_updates(updates)

      updated_attachments = put_media_attachment_at(attachments, index, updated_attachment)

      updated_metadata =
        metadata
        |> Map.put("attachments", updated_attachments)
        |> put_media_attachment_alt_text(index, updates)

      {:ok, updated_metadata, updated_attachment}
    end
  end

  defp find_media_attachment(media_urls, attachments, media_id) do
    media_urls
    |> Enum.with_index()
    |> Enum.find(fn {url, _index} -> media_attachment_ref_matches?(url, media_id) end)
    |> case do
      {url, index} ->
        attachment = Enum.at(attachments, index) || %{}
        {:ok, index, url, attachment}

      nil ->
        find_media_attachment_by_metadata(attachments, media_id)
    end
  end

  defp find_media_attachment_by_metadata(attachments, media_id) do
    attachments
    |> Enum.with_index()
    |> Enum.find(fn {attachment, _index} ->
      media_attachment_ref_matches?(attachment["id"], media_id) ||
        media_attachment_ref_matches?(attachment["url"], media_id)
    end)
    |> case do
      {%{"url" => url} = attachment, index} when is_binary(url) ->
        {:ok, index, url, attachment}

      _ ->
        {:error, :not_found}
    end
  end

  defp media_attachment_ref_matches?(ref, media_id) when is_binary(ref) do
    ref == media_id || media_attachment_id(ref) == media_id
  end

  defp media_attachment_ref_matches?(_ref, _media_id), do: false

  defp media_attachment_updates(attrs) do
    description = media_attachment_description(attrs)
    focus = media_attachment_focus(attrs)

    case {Map.has_key?(attrs, "description") || Map.has_key?(attrs, "text") ||
            Map.has_key?(attrs, "alt_text"), focus} do
      {false, nil} -> {:error, :empty_media_update}
      _ -> {:ok, %{description: description, focus: focus}}
    end
  end

  defp media_attachment_description(attrs) do
    cond do
      Map.has_key?(attrs, "description") -> attrs["description"]
      Map.has_key?(attrs, "text") -> attrs["text"]
      Map.has_key?(attrs, "alt_text") -> attrs["alt_text"]
      true -> :unchanged
    end
  end

  defp media_attachment_focus(%{"focus" => focus}), do: normalize_media_attachment_focus(focus)
  defp media_attachment_focus(_attrs), do: nil

  defp normalize_media_attachment_focus(%{"x" => x, "y" => y}) do
    with {:ok, parsed_x} <- parse_media_attachment_focus_axis(x),
         {:ok, parsed_y} <- parse_media_attachment_focus_axis(y) do
      %{"x" => parsed_x, "y" => parsed_y}
    else
      _ -> nil
    end
  end

  defp normalize_media_attachment_focus(%{x: x, y: y}) do
    normalize_media_attachment_focus(%{"x" => x, "y" => y})
  end

  defp normalize_media_attachment_focus(focus) when is_binary(focus) do
    case String.split(focus, ",", parts: 2) do
      [x, y] -> normalize_media_attachment_focus(%{"x" => x, "y" => y})
      _ -> nil
    end
  end

  defp normalize_media_attachment_focus(_focus), do: nil

  defp parse_media_attachment_focus_axis(value) when is_float(value),
    do: {:ok, clamp_focus(value)}

  defp parse_media_attachment_focus_axis(value) when is_integer(value),
    do: {:ok, clamp_focus(value / 1)}

  defp parse_media_attachment_focus_axis(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> {:ok, clamp_focus(float)}
      _ -> :error
    end
  end

  defp parse_media_attachment_focus_axis(_value), do: :error

  defp clamp_focus(value), do: value |> max(-1.0) |> min(1.0)

  defp apply_media_attachment_updates(attachment, %{description: :unchanged, focus: nil}),
    do: attachment

  defp apply_media_attachment_updates(attachment, %{description: description, focus: focus}) do
    attachment
    |> put_media_attachment_description(description)
    |> put_media_attachment_focus(focus)
  end

  defp put_media_attachment_description(attachment, :unchanged), do: attachment

  defp put_media_attachment_description(attachment, description) when is_binary(description) do
    trimmed = String.trim(description)

    if Elektrine.Strings.present?(trimmed) do
      Map.put(attachment, "alt_text", trimmed)
    else
      Map.delete(attachment, "alt_text")
    end
  end

  defp put_media_attachment_description(attachment, nil), do: Map.delete(attachment, "alt_text")
  defp put_media_attachment_description(attachment, _description), do: attachment

  defp put_media_attachment_focus(attachment, nil), do: attachment
  defp put_media_attachment_focus(attachment, focus), do: Map.put(attachment, "focus", focus)

  defp put_media_attachment_at(attachments, index, attachment) do
    attachments
    |> pad_media_attachments(index)
    |> List.replace_at(index, attachment)
  end

  defp pad_media_attachments(attachments, index) do
    if length(attachments) > index do
      attachments
    else
      attachments ++ List.duplicate(%{}, index - length(attachments) + 1)
    end
  end

  defp put_media_attachment_alt_text(metadata, _index, %{description: :unchanged}), do: metadata

  defp put_media_attachment_alt_text(metadata, index, %{description: description})
       when is_binary(description) do
    trimmed = String.trim(description)
    alt_texts = Map.get(metadata, "alt_texts", %{})

    if Elektrine.Strings.present?(trimmed) do
      Map.put(metadata, "alt_texts", Map.put(alt_texts, to_string(index), trimmed))
    else
      Map.put(metadata, "alt_texts", Map.delete(alt_texts, to_string(index)))
    end
  end

  defp put_media_attachment_alt_text(metadata, index, %{description: nil}) do
    alt_texts = Map.get(metadata, "alt_texts", %{})
    Map.put(metadata, "alt_texts", Map.delete(alt_texts, to_string(index)))
  end

  defp put_media_attachment_alt_text(metadata, _index, _updates), do: metadata

  defp normalize_media_attachment_lookup_id(media_id) do
    media_id
    |> String.trim()
    |> URI.decode_www_form()
  rescue
    ArgumentError -> String.trim(media_id)
  end

  defp normalize_existing_media_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(fn
      attachment when is_map(attachment) ->
        Enum.reduce(attachment, %{}, fn {key, value}, acc ->
          if is_nil(value), do: acc, else: Map.put(acc, to_string(key), value)
        end)

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_existing_media_attachments(_attachments), do: []

  defp normalize_media_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      normalized_key = to_string(key)

      normalized_value =
        if normalized_key == "attachments" do
          normalize_media_attachments(value)
        else
          value
        end

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_media_metadata(_metadata), do: %{}

  defp normalize_media_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_media_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_media_attachments(_attachments), do: []

  defp normalize_media_attachment(attachment) when is_map(attachment) do
    normalized =
      Enum.reduce(attachment, %{}, fn {key, value}, acc ->
        if is_nil(value) do
          acc
        else
          Map.put(acc, to_string(key), value)
        end
      end)

    url = normalized["url"] || normalized["key"]
    mime_type = normalized["mime_type"] || normalized["content_type"]

    if is_binary(url) and is_binary(mime_type) do
      %{}
      |> maybe_put_media_attachment_text("id", normalized["id"] || media_attachment_id(url))
      |> maybe_put_media_attachment_text("url", url)
      |> maybe_put_media_attachment_text("mime_type", mime_type)
      |> maybe_put_media_attachment_text("filename", normalized["filename"])
      |> maybe_put_media_attachment_text("alt_text", normalized["alt_text"])
      |> maybe_put_media_attachment_text(
        "authorization",
        normalized["authorization"] || "public"
      )
      |> maybe_put_media_attachment_text("retention", normalized["retention"] || "origin")
      |> maybe_put_media_attachment_integer(
        "byte_size",
        normalized["byte_size"] || normalized["size"]
      )
      |> maybe_put_media_attachment_integer("width", normalized["width"])
      |> maybe_put_media_attachment_integer("height", normalized["height"])
      |> maybe_put_media_attachment_integer("duration_ms", normalized["duration_ms"])
    end
  end

  defp normalize_media_attachment(_attachment), do: nil

  defp media_attachment_id(url) when is_binary(url) do
    encoded_hash =
      :crypto.hash(:sha256, url)
      |> Base.url_encode64(padding: false)

    "attachment-#{encoded_hash}"
  end

  defp maybe_put_media_attachment_text(map, _key, nil), do: map

  defp maybe_put_media_attachment_text(map, key, value) when is_binary(value) do
    trimmed = String.trim(value)
    if Elektrine.Strings.present?(trimmed), do: Map.put(map, key, trimmed), else: map
  end

  defp maybe_put_media_attachment_text(map, _key, _value), do: map

  defp maybe_put_media_attachment_integer(map, key, value)
       when is_integer(value) and value >= 0 do
    Map.put(map, key, value)
  end

  defp maybe_put_media_attachment_integer(map, _key, _value), do: map

  defp maybe_merge_attachment_alt_texts(metadata, nil), do: metadata

  defp maybe_merge_attachment_alt_texts(metadata, alt_texts)
       when is_map(metadata) and is_map(alt_texts) and map_size(alt_texts) > 0 do
    case Map.get(metadata, "attachments") do
      attachments when is_list(attachments) ->
        merged_attachments =
          attachments
          |> Enum.with_index()
          |> Enum.map(fn {attachment, index} ->
            attachment
            |> normalize_media_metadata()
            |> maybe_put_attachment_alt_text(Map.get(alt_texts, to_string(index)))
          end)

        Map.put(metadata, "attachments", merged_attachments)

      _ ->
        metadata
    end
  end

  defp maybe_merge_attachment_alt_texts(metadata, _alt_texts), do: metadata

  defp maybe_put_attachment_alt_text(attachment, nil), do: attachment

  defp maybe_put_attachment_alt_text(attachment, alt_text)
       when is_map(attachment) and is_binary(alt_text) do
    trimmed = String.trim(alt_text)

    if Elektrine.Strings.present?(trimmed) do
      Map.put(attachment, "alt_text", trimmed)
    else
      attachment
    end
  end

  defp maybe_put_attachment_alt_text(attachment, _alt_text), do: attachment

  defp maybe_put_alt_texts(metadata, nil), do: metadata
  defp maybe_put_alt_texts(metadata, alt_texts) when not is_map(alt_texts), do: metadata
  defp maybe_put_alt_texts(metadata, alt_texts) when map_size(alt_texts) == 0, do: metadata
  defp maybe_put_alt_texts(metadata, alt_texts), do: Map.put(metadata, "alt_texts", alt_texts)

  defp maybe_put_community_actor_uri(metadata, nil), do: metadata
  defp maybe_put_community_actor_uri(metadata, ""), do: metadata

  defp maybe_put_community_actor_uri(metadata, community_actor_uri)
       when is_binary(community_actor_uri) do
    normalized = String.trim(community_actor_uri)

    if not Elektrine.Strings.present?(normalized) || normalized in @public_audience_uris do
      metadata
    else
      Map.put(metadata, "community_actor_uri", normalized)
    end
  end

  defp maybe_put_community_actor_uri(metadata, _community_actor_uri), do: metadata
end
