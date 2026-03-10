defmodule Elektrine.Messaging.Federation.Mirrors do
  @moduledoc false

  import Ecto.Query, warn: false
  import Elektrine.Messaging.Federation.Utils

  alias Elektrine.Messaging.{ChatMessage, Conversation, Server}
  alias Elektrine.Repo

  def ensure_channel_event_context(data, remote_domain, context)
      when is_map(data) and is_binary(remote_domain) and is_map(context) do
    with %{} = server_payload <- event_server_payload(data),
         %{} = channel_payload <- event_channel_payload(data),
         {:ok, mirror_server} <- ensure_mirror_server_from_event(server_payload, remote_domain),
         {:ok, mirror_channel} <-
           ensure_mirror_channel_from_event(mirror_server, channel_payload) do
      {:ok, mirror_server, mirror_channel}
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  def ensure_channel_event_context(_data, _remote_domain, _context),
    do: {:error, :invalid_event_payload}

  def ensure_server_event_context(data, remote_domain, _context)
      when is_map(data) and is_binary(remote_domain) do
    with %{} = server_payload <- event_server_payload(data),
         {:ok, mirror_server} <- ensure_mirror_server_from_event(server_payload, remote_domain) do
      {:ok, mirror_server}
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  def ensure_server_event_context(_data, _remote_domain, _context),
    do: {:error, :invalid_event_payload}

  def event_server_payload(data) when is_map(data) do
    server_id = event_server_id(data)

    case data["server"] do
      %{} = server when is_binary(server_id) -> Map.put_new(server, "id", server_id)
      %{} = server -> server
      _ when is_binary(server_id) -> %{"id" => server_id}
      _ -> nil
    end
  end

  def event_server_payload(_data), do: nil

  def upsert_mirror_server(server_payload, remote_domain)
      when is_map(server_payload) and is_binary(remote_domain) do
    attrs = %{
      name: server_payload["name"],
      description: server_payload["description"],
      icon_url: server_payload["icon_url"],
      is_public: server_payload["is_public"] == true,
      member_count: parse_int(server_payload["member_count"], 0),
      federation_id: server_payload["id"],
      origin_domain: remote_domain,
      is_federated_mirror: true,
      last_federated_at: DateTime.utc_now()
    }

    case Repo.get_by(Server, federation_id: server_payload["id"]) do
      nil ->
        %Server{} |> Server.changeset(attrs) |> Repo.insert()

      %Server{origin_domain: existing_origin} = server ->
        if is_binary(existing_origin) and existing_origin != remote_domain do
          {:error, :federation_origin_conflict}
        else
          server |> Server.changeset(attrs) |> Repo.update()
        end
    end
  end

  def upsert_mirror_server(_server_payload, _remote_domain), do: {:error, :invalid_event_payload}

  def upsert_mirror_channels(server, channels, context)
      when is_list(channels) and is_map(context) do
    channels
    |> Enum.reduce_while({:ok, %{}}, fn payload, {:ok, acc} ->
      case upsert_single_mirror_channel(server, payload) do
        {:ok, channel} ->
          {:cont, {:ok, Map.put(acc, payload["id"], channel)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def upsert_mirror_channels(_server, _channels, _context), do: {:error, :invalid_event_payload}

  def upsert_single_mirror_channel(server, %{"id" => channel_id} = channel_payload)
      when is_map(server) and is_binary(channel_id) do
    attrs = %{
      name: channel_payload["name"] || "channel",
      description: channel_payload["description"],
      channel_topic: channel_payload["topic"],
      channel_position: parse_int(channel_payload["position"], 0),
      creator_id: nil,
      server_id: server.id,
      is_public: true,
      is_federated_mirror: true,
      federated_source: channel_id
    }

    case Repo.get_by(Conversation, type: "channel", federated_source: channel_id) do
      nil ->
        %Conversation{} |> Conversation.channel_changeset(attrs) |> Repo.insert()

      %Conversation{} = channel ->
        with :ok <- ensure_channel_origin_matches(channel, server.origin_domain) do
          channel |> Conversation.changeset(attrs) |> Repo.update()
        end
    end
  end

  def upsert_single_mirror_channel(_server, _channel_payload), do: {:error, :invalid_channel}

  def upsert_mirror_messages(channel_map, messages, remote_domain, context)
      when is_map(channel_map) and is_list(messages) and is_binary(remote_domain) and
             is_map(context) do
    messages
    |> Enum.reduce_while(:ok, fn payload, :ok ->
      channel = Map.get(channel_map, payload["channel_id"])

      if channel do
        case upsert_mirror_message(channel, payload, remote_domain, context) do
          {:ok, _result} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  def upsert_mirror_messages(_channel_map, _messages, _remote_domain, _context),
    do: {:error, :invalid_event_payload}

  def upsert_mirror_message(channel, payload, remote_domain, context)
      when is_map(context) and is_binary(remote_domain) do
    federation_id = payload["id"]

    cond do
      is_nil(channel) ->
        {:error, :invalid_channel}

      !is_binary(federation_id) ->
        {:error, :invalid_message_payload}

      Repo.get_by(ChatMessage, conversation_id: channel.id, federated_source: federation_id) ->
        {:ok, :duplicate}

      true ->
        attachments = call(context, :normalize_message_attachments, [payload])

        media_metadata =
          call(context, :attachment_storage_metadata, [attachments])
          |> Map.put("remote_sender", payload["sender"] || %{})

        attrs = %{
          conversation_id: channel.id,
          sender_id: nil,
          content: payload["content"],
          message_type: normalize_message_type(payload["message_type"]),
          media_urls: Enum.map(attachments, & &1["url"]),
          media_metadata: media_metadata,
          federated_source: federation_id,
          origin_domain: remote_domain,
          is_federated_mirror: true
        }

        %ChatMessage{} |> ChatMessage.changeset(attrs) |> Repo.insert()
    end
  end

  def upsert_mirror_message(_channel, _payload, _remote_domain, _context),
    do: {:error, :invalid_event_payload}

  def upsert_or_update_mirror_message(channel, payload, remote_domain, context)
      when is_map(context) and is_binary(remote_domain) do
    federation_id = payload["id"]

    with true <- is_binary(federation_id),
         %ChatMessage{} = existing <-
           Repo.get_by(ChatMessage, conversation_id: channel.id, federated_source: federation_id) do
      attachments = call(context, :normalize_message_attachments, [payload])

      media_metadata =
        call(context, :attachment_storage_metadata, [attachments])
        |> Map.put("remote_sender", payload["sender"] || %{})

      attrs = %{
        content: payload["content"],
        message_type: normalize_message_type(payload["message_type"]),
        media_urls: Enum.map(attachments, & &1["url"]),
        media_metadata: media_metadata,
        edited_at: parse_datetime(payload["edited_at"]) || DateTime.utc_now()
      }

      existing
      |> ChatMessage.changeset(attrs)
      |> Repo.update()
    else
      _ -> upsert_mirror_message(channel, payload, remote_domain, context)
    end
  end

  def upsert_or_update_mirror_message(_channel, _payload, _remote_domain, _context),
    do: {:error, :invalid_event_payload}

  def soft_delete_mirror_message(channel, federation_message_id, deleted_at)
      when is_map(channel) and is_binary(federation_message_id) do
    case Repo.get_by(ChatMessage,
           conversation_id: channel.id,
           federated_source: federation_message_id
         ) do
      nil ->
        {:error, :not_found}

      %ChatMessage{} = message ->
        attrs = %{deleted_at: parse_datetime(deleted_at) || DateTime.utc_now()}

        case message |> ChatMessage.changeset(attrs) |> Repo.update() do
          {:ok, updated} -> {:ok, updated}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def soft_delete_mirror_message(_channel, _federation_message_id, _deleted_at),
    do: {:error, :invalid_event_payload}

  def get_mirror_message(channel, federation_message_id)
      when is_map(channel) and is_binary(federation_message_id) do
    case Repo.get_by(ChatMessage,
           conversation_id: channel.id,
           federated_source: federation_message_id
         ) do
      nil -> {:error, :not_found}
      %ChatMessage{} = message -> {:ok, message}
    end
  end

  def get_mirror_message(_channel, _federation_message_id), do: {:error, :invalid_event_payload}

  defp event_channel_payload(data) when is_map(data) do
    channel_id = event_channel_id(data)

    case data["channel"] do
      %{} = channel when is_binary(channel_id) -> Map.put_new(channel, "id", channel_id)
      %{} = channel -> channel
      _ when is_binary(channel_id) -> %{"id" => channel_id}
      _ -> nil
    end
  end

  defp event_channel_payload(_data), do: nil

  defp event_server_id(data) when is_map(data) do
    refs = data["refs"] || %{}
    get_in(data, ["server", "id"]) || refs["server_id"]
  end

  defp event_server_id(_data), do: nil

  defp event_channel_id(data) when is_map(data) do
    refs = data["refs"] || %{}
    get_in(data, ["channel", "id"]) || refs["channel_id"]
  end

  defp event_channel_id(_data), do: nil

  defp ensure_mirror_server_from_event(%{"id" => server_id} = server_payload, remote_domain)
       when is_binary(server_id) and is_binary(remote_domain) do
    if Map.has_key?(server_payload, "name") do
      upsert_mirror_server(server_payload, remote_domain)
    else
      case Repo.get_by(Server, federation_id: server_id) do
        %Server{origin_domain: ^remote_domain} = server ->
          {:ok, server}

        %Server{origin_domain: nil} = server ->
          {:ok, server}

        %Server{} ->
          {:error, :federation_origin_conflict}

        nil ->
          {:error, :invalid_event_payload}
      end
    end
  end

  defp ensure_mirror_server_from_event(_server_payload, _remote_domain),
    do: {:error, :invalid_event_payload}

  defp ensure_mirror_channel_from_event(
         %Server{} = server,
         %{"id" => channel_id} = channel_payload
       )
       when is_binary(channel_id) do
    if Map.has_key?(channel_payload, "name") do
      upsert_single_mirror_channel(server, channel_payload)
    else
      case Repo.get_by(Conversation, type: "channel", federated_source: channel_id) do
        %Conversation{server_id: server_id} = channel when server_id == server.id ->
          with :ok <- ensure_channel_origin_matches(channel, server.origin_domain) do
            {:ok, channel}
          end

        %Conversation{} ->
          {:error, :federation_origin_conflict}

        nil ->
          {:error, :invalid_event_payload}
      end
    end
  end

  defp ensure_mirror_channel_from_event(_server, _channel_payload),
    do: {:error, :invalid_event_payload}

  defp ensure_channel_origin_matches(%Conversation{server_id: server_id}, remote_domain)
       when is_integer(server_id) and is_binary(remote_domain) do
    case Repo.get(Server, server_id) do
      %Server{origin_domain: ^remote_domain} -> :ok
      %Server{origin_domain: nil} -> :ok
      %Server{} -> {:error, :federation_origin_conflict}
      nil -> {:error, :federation_origin_conflict}
    end
  end

  defp ensure_channel_origin_matches(_channel, _remote_domain),
    do: {:error, :federation_origin_conflict}

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
