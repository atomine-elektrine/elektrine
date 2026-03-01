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

  def message_payload(message, channel) do
    %{
      "id" => message.federated_source || message_federation_id(message.id),
      "channel_id" => channel.federated_source || channel_federation_id(channel.id),
      "content" => message.content,
      "message_type" => message.message_type,
      "media_urls" => message.media_urls || [],
      "media_metadata" => message.media_metadata || %{},
      "created_at" => format_created_at(message.inserted_at),
      "edited_at" => format_created_at(message.edited_at),
      "sender" => format_sender(message.sender)
    }
  end

  def sender_payload(user) do
    %{
      "uri" => "#{local_base_url()}/users/#{user.username}",
      "username" => user.username,
      "display_name" => user.display_name || user.username,
      "domain" => local_domain(),
      "handle" => "#{user.username}@#{local_domain()}"
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

  def format_sender(nil) do
    nil
  end

  def format_sender(sender) do
    %{
      "username" => sender.username,
      "display_name" => sender.display_name || sender.username,
      "domain" => local_domain(),
      "handle" => "#{sender.username}@#{local_domain()}"
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
    payload_data = payload["payload"] || payload["data"] || %{}
    server_id_from_data = get_in(payload_data, ["server", "id"]) |> extract_trailing_integer()
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
