defmodule Elektrine.Messaging.Federation.Utils do
  @moduledoc false

  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Repo

  def next_outbound_sequence(stream_id) do
    sql =
      "INSERT INTO messaging_federation_stream_counters (stream_id, next_sequence, inserted_at, updated_at)\nVALUES ($1, 2, NOW(), NOW())\nON CONFLICT (stream_id)\nDO UPDATE\n  SET next_sequence = messaging_federation_stream_counters.next_sequence + 1,\n      updated_at = NOW()\nRETURNING next_sequence - 1\n"

    case Ecto.Adapters.SQL.query(Repo, sql, [stream_id]) do
      {:ok, %{rows: [[sequence]]}} when is_integer(sequence) -> sequence
      _ -> 1
    end
  end

  def server_stream_id(server_id) do
    "server:" <> server_federation_id(server_id)
  end

  def channel_stream_id(channel_id) do
    "channel:" <> channel_federation_id(channel_id)
  end

  def dm_stream_id(conversation_id) do
    "dm:" <> dm_federation_id(conversation_id)
  end

  def server_payload(server) do
    %{
      "id" => server.federation_id || server_federation_id(server.id),
      "name" => server.name,
      "description" => server.description,
      "icon_url" => server.icon_url,
      "is_public" => server.is_public,
      "member_count" => server.member_count
    }
  end

  def channel_payload(channel) do
    %{
      "id" => channel.federated_source || channel_federation_id(channel.id),
      "name" => channel.name,
      "description" => channel.description,
      "topic" => channel.channel_topic,
      "position" => channel.channel_position
    }
  end

  def event_refs_payload(server, channel) do
    %{
      "server_id" => server.federation_id || server_federation_id(server.id),
      "channel_id" => channel.federated_source || channel_federation_id(channel.id)
    }
  end

  def message_payload(message, channel) do
    %{
      "id" => message.federated_source || message_federation_id(message.id),
      "channel_id" => channel.federated_source || channel_federation_id(channel.id),
      "content" => message.content,
      "message_type" => message.message_type,
      "attachments" => attachment_payloads(message),
      "created_at" => format_created_at(message.inserted_at),
      "edited_at" => format_created_at(message.edited_at),
      "sender" => format_sender(message.sender)
    }
  end

  def event_message_payload(message) do
    %{
      "id" => message.federated_source || message_federation_id(message.id),
      "content" => message.content,
      "message_type" => message.message_type,
      "attachments" => attachment_payloads(message),
      "created_at" => format_created_at(message.inserted_at),
      "edited_at" => format_created_at(message.edited_at),
      "sender" => format_sender(message.sender)
    }
  end

  def attachment_payloads(message) do
    metadata = attachment_metadata_source(message)
    metadata_attachments = normalize_metadata_attachments(metadata["attachments"])
    media_urls = normalize_media_urls(message.media_urls || [])

    if metadata_attachments != [] do
      metadata_attachments
    else
      media_urls
      |> Enum.with_index()
      |> Enum.map(fn {url, index} ->
        %{
          "id" => attachment_id(metadata, url, index),
          "url" => url,
          "mime_type" => attachment_mime_type(metadata, index),
          "byte_size" => attachment_numeric(metadata, "byte_sizes", index),
          "sha256" => attachment_text(metadata, "sha256", index),
          "authorization" => attachment_authorization(metadata, index),
          "retention" => attachment_retention(metadata, index),
          "expires_at" => attachment_text(metadata, "expires_at", index),
          "alt_text" => attachment_text(metadata, "alt_texts", index),
          "width" => attachment_numeric(metadata, "widths", index),
          "height" => attachment_numeric(metadata, "heights", index),
          "duration_ms" => attachment_numeric(metadata, "duration_ms", index)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
      end)
    end
  end

  def sender_payload(user) do
    uri = "#{local_base_url()}/users/#{user.username}"
    handle = "#{user.username}@#{local_domain()}"

    %{
      "id" => uri,
      "uri" => uri,
      "username" => user.username,
      "display_name" => user.display_name || user.username,
      "domain" => local_domain(),
      "handle" => handle
    }
  end

  def truncate(nil) do
    ""
  end

  def truncate(body) when is_binary(body) do
    if byte_size(body) > 180 do
      binary_part(body, 0, 180) <> "..."
    else
      body
    end
  end

  def truncate(body) do
    inspect(body)
  end

  def normalize_message_type(type) when type in ["text", "image", "file", "voice", "system"] do
    type
  end

  def normalize_message_type(_) do
    "text"
  end

  def canonical_path(nil) do
    "/"
  end

  def canonical_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> "/"
      String.starts_with?(trimmed, "/") -> trimmed
      true -> "/" <> trimmed
    end
  end

  def canonical_path(path) do
    canonical_path(to_string(path))
  end

  def canonical_query_string(nil) do
    ""
  end

  def canonical_query_string(query) when is_binary(query) do
    String.trim(query)
  end

  def canonical_query_string(query) do
    to_string(query)
  end

  def canonical_content_digest(nil) do
    body_digest("")
  end

  def canonical_content_digest(content_digest) when is_binary(content_digest) do
    case String.trim(content_digest) do
      "" -> body_digest("")
      value -> value
    end
  end

  def canonical_content_digest(content_digest) do
    canonical_content_digest(to_string(content_digest))
  end

  def normalize_media_urls(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(10)
  end

  def normalize_media_urls(_values), do: []

  def server_federation_id(server_id) do
    "#{local_base_url()}/federation/messaging/servers/#{server_id}"
  end

  def channel_federation_id(channel_id) do
    "#{local_base_url()}/federation/messaging/channels/#{channel_id}"
  end

  def message_federation_id(message_id) do
    "#{local_base_url()}/federation/messaging/messages/#{message_id}"
  end

  def dm_federation_id(conversation_id) do
    "#{local_base_url()}/federation/messaging/dms/#{conversation_id}"
  end

  defp attachment_metadata_source(message) do
    case Map.get(message, :media_metadata) do
      %{} = metadata -> metadata
      _ -> %{}
    end
  end

  defp normalize_metadata_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn attachment ->
      attachment
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        if is_nil(value), do: acc, else: Map.put(acc, to_string(key), value)
      end)
    end)
    |> Enum.filter(fn attachment ->
      is_binary(attachment["id"]) and
        is_binary(attachment["url"]) and
        is_binary(attachment["mime_type"])
    end)
  end

  defp normalize_metadata_attachments(_attachments), do: []

  defp attachment_id(metadata, url, index) do
    attachment_text(metadata, "ids", index) ||
      attachment_text(metadata, "attachment_ids", index) ||
      "#{index}-#{:crypto.hash(:sha256, url) |> Base.url_encode64(padding: false)}"
  end

  defp attachment_mime_type(metadata, index) do
    attachment_text(metadata, "mime_types", index) || "application/octet-stream"
  end

  defp attachment_authorization(metadata, index) do
    attachment_text(metadata, "authorization", index) || "public"
  end

  defp attachment_retention(metadata, index) do
    attachment_text(metadata, "retention", index) || "origin"
  end

  defp attachment_text(metadata, key, index) when is_map(metadata) and is_binary(key) do
    case Map.get(metadata, key) do
      %{} = values -> values[to_string(index)] || values[index]
      values when is_list(values) -> Enum.at(values, index)
      value when is_binary(value) and index == 0 -> value
      _ -> nil
    end
    |> case do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp attachment_text(_metadata, _key, _index), do: nil

  defp attachment_numeric(metadata, key, index) when is_map(metadata) and is_binary(key) do
    case Map.get(metadata, key) do
      %{} = values -> values[to_string(index)] || values[index]
      values when is_list(values) -> Enum.at(values, index)
      value when is_integer(value) and index == 0 -> value
      _ -> nil
    end
    |> case do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp attachment_numeric(_metadata, _key, _index), do: nil

  def format_sender(nil) do
    nil
  end

  def format_sender(sender) do
    uri = "#{local_base_url()}/users/#{sender.username}"
    handle = "#{sender.username}@#{local_domain()}"

    %{
      "id" => uri,
      "uri" => uri,
      "username" => sender.username,
      "display_name" => sender.display_name || sender.username,
      "domain" => local_domain(),
      "handle" => handle
    }
  end

  def format_created_at(nil) do
    nil
  end

  def format_created_at(%DateTime{} = datetime) do
    DateTime.to_iso8601(datetime)
  end

  def format_created_at(%NaiveDateTime{} = datetime) do
    NaiveDateTime.to_iso8601(datetime)
  end

  def parse_datetime(nil), do: nil

  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  def parse_datetime(_), do: nil

  def parse_int(value, _default) when is_integer(value) do
    value
  end

  def parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  def parse_int(_, default) do
    default
  end

  def infer_remote_server_id(payload) when is_map(payload) do
    payload_data = payload["payload"] || %{}
    refs = payload_data["refs"] || %{}

    server_id_from_data =
      (get_in(payload_data, ["server", "id"]) || refs["server_id"])
      |> extract_trailing_integer()

    stream_id = payload["stream_id"]

    server_id_from_stream =
      case stream_id do
        "server:" <> server_federation_id -> extract_trailing_integer(server_federation_id)
        _ -> nil
      end

    case server_id_from_data || server_id_from_stream do
      nil -> {:error, :cannot_infer_snapshot_server_id}
      id -> {:ok, id}
    end
  end

  def infer_remote_server_id(_) do
    {:error, :cannot_infer_snapshot_server_id}
  end

  def infer_remote_server_id_from_federation_id(federation_id) when is_binary(federation_id) do
    case extract_trailing_integer(federation_id) do
      nil -> {:error, :cannot_infer_snapshot_server_id}
      id -> {:ok, id}
    end
  end

  def infer_remote_server_id_from_federation_id(_) do
    {:error, :cannot_infer_snapshot_server_id}
  end

  def extract_trailing_integer(nil) do
    nil
  end

  def extract_trailing_integer(value) when is_binary(value) do
    value
    |> String.trim_trailing("/")
    |> String.split("/")
    |> List.last()
    |> case do
      nil ->
        nil

      candidate ->
        case Integer.parse(candidate) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end

  def extract_trailing_integer(_) do
    nil
  end

  defp body_digest(body) when is_binary(body) do
    "sha-256=" <> ArblargSDK.body_digest(body)
  end

  defp local_domain do
    Elektrine.Messaging.Federation.local_domain()
  end

  defp local_base_url do
    configured =
      federation_config()
      |> Keyword.get(:base_url)
      |> normalize_optional_string()

    configured || infer_local_base_url(local_domain())
  end

  defp infer_local_base_url(domain) when is_binary(domain) do
    is_tunnel = String.contains?(domain, ".") and not String.starts_with?(domain, "localhost")
    scheme = if System.get_env("MIX_ENV") == "prod" or is_tunnel, do: "https", else: "http"
    port = System.get_env("PORT") || "4000"

    if scheme == "https" or port in ["80", "443"] or is_tunnel do
      "#{scheme}://#{domain}"
    else
      "#{scheme}://#{domain}:#{port}"
    end
  end

  defp federation_config do
    Application.get_env(:elektrine, :messaging_federation, [])
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_), do: nil
end
