defmodule Elektrine.Messaging.Federation.Attachments do
  @moduledoc false

  import Elektrine.Messaging.Federation.Utils

  def normalize_message_attachments(message_payload) when is_map(message_payload) do
    case message_payload["attachments"] do
      attachments when is_list(attachments) ->
        attachments
        |> Enum.filter(&valid_attachment_payload?/1)
        |> Enum.map(&normalize_attachment_payload/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(10)

      _ ->
        legacy_urls = normalize_media_urls(message_payload["media_urls"])

        legacy_metadata =
          if is_map(message_payload["media_metadata"]),
            do: message_payload["media_metadata"],
            else: %{}

        legacy_urls
        |> Enum.with_index()
        |> Enum.map(fn {url, index} ->
          %{
            "id" => "legacy-#{index}",
            "url" => url,
            "mime_type" => "application/octet-stream",
            "authorization" => "public",
            "retention" => "origin",
            "alt_text" => legacy_attachment_text(legacy_metadata, "alt_texts", index)
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
        end)
    end
  end

  def normalize_message_attachments(_message_payload), do: []

  def attachment_storage_metadata(attachments) when is_list(attachments) do
    %{"attachments" => attachments}
  end

  def attachment_storage_metadata(_attachments), do: %{"attachments" => []}

  defp valid_attachment_payload?(attachment) when is_map(attachment) do
    authorization = normalize_optional_string(attachment["authorization"])
    retention = normalize_optional_string(attachment["retention"])

    is_binary(normalize_optional_string(attachment["id"])) and
      is_binary(normalize_optional_string(attachment["url"])) and
      is_binary(normalize_optional_string(attachment["mime_type"])) and
      authorization in ["public", "signed", "origin-authenticated"] and
      retention in ["origin", "rehosted", "expiring"]
  end

  defp valid_attachment_payload?(_attachment), do: false

  defp normalize_attachment_payload(attachment) when is_map(attachment) do
    %{}
    |> maybe_put_optional_map_value("id", attachment["id"])
    |> maybe_put_optional_map_value("url", attachment["url"])
    |> maybe_put_optional_map_value("mime_type", attachment["mime_type"])
    |> maybe_put_optional_map_value("sha256", attachment["sha256"])
    |> maybe_put_optional_map_value("authorization", attachment["authorization"])
    |> maybe_put_optional_map_value("retention", attachment["retention"])
    |> maybe_put_optional_map_value("expires_at", attachment["expires_at"])
    |> maybe_put_optional_map_value("alt_text", attachment["alt_text"])
    |> maybe_put_optional_integer_value("byte_size", attachment["byte_size"])
    |> maybe_put_optional_integer_value("width", attachment["width"])
    |> maybe_put_optional_integer_value("height", attachment["height"])
    |> maybe_put_optional_integer_value("duration_ms", attachment["duration_ms"])
  end

  defp normalize_attachment_payload(_attachment), do: nil

  defp legacy_attachment_text(metadata, key, index) when is_map(metadata) and is_binary(key) do
    case Map.get(metadata, key) do
      %{} = values ->
        case values[to_string(index)] || values[index] do
          value when is_binary(value) ->
            trimmed = String.trim(value)
            if Elektrine.Strings.present?(trimmed), do: trimmed, else: nil

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp legacy_attachment_text(_metadata, _key, _index), do: nil

  defp maybe_put_optional_map_value(map, _key, nil), do: map

  defp maybe_put_optional_map_value(map, key, value) when is_binary(value) do
    trimmed = String.trim(value)
    if Elektrine.Strings.present?(trimmed), do: Map.put(map, key, trimmed), else: map
  end

  defp maybe_put_optional_map_value(map, _key, _value), do: map

  defp maybe_put_optional_integer_value(map, key, value)
       when is_integer(value) and value >= 0 do
    Map.put(map, key, value)
  end

  defp maybe_put_optional_integer_value(map, _key, _value), do: map

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_value), do: nil
end
