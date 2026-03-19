defmodule Elektrine.Messaging.Federation.Mirrors do
  @moduledoc false

  import Ecto.Query, warn: false
  import Elektrine.Messaging.Federation.Utils

  alias Elektrine.Messaging.{
    ChatMessage,
    Conversation,
    RoomACL,
    Server
  }

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

  def ensure_authoritative_channel_event_context(data, remote_domain, context)
      when is_map(data) and is_binary(remote_domain) and is_map(context) do
    with {:ok, server, channel} <- resolve_channel_event_context(data, remote_domain, context),
         authority_domain when is_binary(authority_domain) <- room_authority_domain(server, data),
         true <-
           normalize_domain(authority_domain) == normalize_domain(remote_domain) or
             {:error, :not_authorized_for_room} do
      {:ok, server, channel}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_event_payload}
    end
  end

  def ensure_authoritative_channel_event_context(_data, _remote_domain, _context),
    do: {:error, :invalid_event_payload}

  def resolve_channel_event_context(data, remote_domain, context)
      when is_map(data) and is_binary(remote_domain) and is_map(context) do
    channel_id = event_channel_id(data)
    server_id = event_server_id(data)
    room_origin_domain = event_room_origin_domain(data)

    with channel_id when is_binary(channel_id) <- channel_id,
         room_origin_domain when is_binary(room_origin_domain) <- room_origin_domain do
      case resolve_existing_channel_context(server_id, channel_id) do
        {:ok, server, channel} ->
          {:ok, server, channel}

        {:error, :not_found} ->
          with true <- normalize_domain(room_origin_domain) == normalize_domain(remote_domain),
               %{} = server_payload <- event_server_payload(data),
               %{} = channel_payload <- event_channel_payload(data),
               {:ok, mirror_server} <-
                 ensure_mirror_server_from_event(server_payload, remote_domain),
               {:ok, mirror_channel} <-
                 ensure_mirror_channel_from_event(mirror_server, channel_payload) do
            {:ok, mirror_server, mirror_channel}
          else
            {:error, :federation_origin_conflict} = error -> error
            _ -> {:error, :invalid_event_payload}
          end

        {:error, :federation_origin_conflict} = error ->
          error
      end
    else
      _ -> {:error, :invalid_event_payload}
    end
  end

  def resolve_channel_event_context(_data, _remote_domain, _context),
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
      is_public: channel_payload["is_public"] == true,
      approval_mode_enabled: channel_payload["approval_mode_enabled"] == true,
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
        message_origin_domain = message_origin_domain(payload, remote_domain)

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
          origin_domain: message_origin_domain,
          is_federated_mirror: channel.is_federated_mirror == true
        }

        %ChatMessage{} |> ChatMessage.changeset(attrs) |> Repo.insert()
    end
  end

  def upsert_mirror_message(_channel, _payload, _remote_domain, _context),
    do: {:error, :invalid_event_payload}

  def upsert_or_update_mirror_message(channel, payload, remote_domain, context)
      when is_map(context) and is_binary(remote_domain) do
    federation_id = payload["id"]

    case is_binary(federation_id) do
      true ->
        case Repo.get_by(ChatMessage,
               conversation_id: channel.id,
               federated_source: federation_id
             ) do
          %ChatMessage{} = existing ->
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

          nil when channel.is_federated_mirror == true ->
            upsert_mirror_message(channel, payload, remote_domain, context)

          nil ->
            {:error, :not_found}
        end

      false ->
        {:error, :invalid_event_payload}
    end
  end

  def upsert_or_update_mirror_message(_channel, _payload, _remote_domain, _context),
    do: {:error, :invalid_event_payload}

  def soft_delete_mirror_message(channel, federation_message_id, deleted_at, remote_domain)
      when is_map(channel) and is_binary(federation_message_id) and is_binary(remote_domain) do
    case Repo.get_by(ChatMessage,
           conversation_id: channel.id,
           federated_source: federation_message_id
         ) do
      nil when channel.is_federated_mirror == true ->
        %ChatMessage{}
        |> ChatMessage.changeset(%{
          conversation_id: channel.id,
          federated_source: federation_message_id,
          origin_domain: String.downcase(remote_domain),
          is_federated_mirror: true,
          message_type: "text",
          deleted_at: parse_datetime(deleted_at) || DateTime.utc_now()
        })
        |> Repo.insert()

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

  def soft_delete_mirror_message(_channel, _federation_message_id, _deleted_at, _remote_domain),
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

  def ensure_remote_actor_membership(channel, remote_actor_id, remote_domain, action \\ :write)

  def ensure_remote_actor_membership(channel, remote_actor_id, _remote_domain, action)
      when is_map(channel) and is_integer(remote_actor_id) and action in [:read, :write] do
    case Repo.get(Server, channel.server_id) do
      %Server{} ->
        remote_action = if action == :read, do: :participate, else: :write
        RoomACL.authorize_remote_actor_action(channel, remote_actor_id, remote_action)

      _ ->
        {:error, :invalid_event_payload}
    end
  end

  def ensure_remote_actor_membership(_channel, _remote_actor_id, _remote_domain, _action),
    do: {:error, :invalid_event_payload}

  def ensure_remote_actor_governance_permission(
        channel,
        remote_actor_id,
        action,
        options \\ %{}
      )

  def ensure_remote_actor_governance_permission(
        channel,
        remote_actor_id,
        action,
        options
      )
      when is_map(channel) and is_integer(remote_actor_id) and is_atom(action) and is_map(options) do
    RoomACL.authorize_remote_actor_action(channel, remote_actor_id, action, options)
  end

  def ensure_remote_actor_governance_permission(_channel, _remote_actor_id, _action, _options),
    do: {:error, :invalid_event_payload}

  def ensure_remote_message_author(channel, federation_message_id, remote_domain)
      when is_map(channel) and is_binary(federation_message_id) and is_binary(remote_domain) do
    case Repo.get_by(ChatMessage,
           conversation_id: channel.id,
           federated_source: federation_message_id
         ) do
      %ChatMessage{origin_domain: origin_domain} ->
        if normalize_domain(origin_domain) == normalize_domain(remote_domain) do
          :ok
        else
          {:error, :not_authorized_for_room}
        end

      nil ->
        if channel.is_federated_mirror == true do
          :ok
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :not_authorized_for_room}
    end
  end

  def ensure_remote_message_author(_channel, _federation_message_id, _remote_domain),
    do: {:error, :invalid_event_payload}

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

  defp event_room_origin_domain(data) when is_map(data) do
    server_host = data |> event_server_id() |> uri_host()
    channel_host = data |> event_channel_id() |> uri_host()

    cond do
      is_binary(server_host) and is_binary(channel_host) and server_host == channel_host ->
        server_host

      is_binary(server_host) and is_binary(channel_host) ->
        nil

      is_binary(channel_host) ->
        channel_host

      is_binary(server_host) ->
        server_host

      true ->
        nil
    end
  end

  defp event_room_origin_domain(_data), do: nil

  defp room_authority_domain(%Server{} = server, data) when is_map(data) do
    normalize_domain(
      server.origin_domain ||
        server.federation_id |> uri_host() ||
        event_room_origin_domain(data) ||
        Elektrine.Messaging.Federation.local_domain()
    )
  end

  defp room_authority_domain(_server, _data), do: nil

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

  defp resolve_existing_channel_context(server_id, channel_id)
       when is_binary(channel_id) do
    case resolve_channel_by_federation_id(channel_id) do
      %Conversation{server_id: conversation_server_id} = channel
      when is_integer(conversation_server_id) ->
        case Repo.get(Server, conversation_server_id) do
          %Server{} = server ->
            if channel_matches_identifier?(channel, channel_id) and
                 (is_nil(server_id) or server_matches_identifier?(server, server_id)) do
              {:ok, server, channel}
            else
              {:error, :federation_origin_conflict}
            end

          _ ->
            {:error, :invalid_event_payload}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp resolve_existing_channel_context(_server_id, _channel_id),
    do: {:error, :invalid_event_payload}

  defp resolve_channel_by_federation_id(channel_id) when is_binary(channel_id) do
    case Repo.get_by(Conversation, type: "channel", federated_source: channel_id) do
      %Conversation{} = channel ->
        channel

      nil ->
        case local_resource_id(channel_id, "channels") do
          id when is_integer(id) ->
            case Repo.get(Conversation, id) do
              %Conversation{type: "channel"} = channel -> channel
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp resolve_channel_by_federation_id(_channel_id), do: nil

  defp server_matches_identifier?(%Server{} = server, identifier) when is_binary(identifier) do
    normalize_identifier(server.federation_id || server_federation_id(server.id)) ==
      normalize_identifier(identifier)
  end

  defp server_matches_identifier?(_server, _identifier), do: false

  defp channel_matches_identifier?(%Conversation{} = channel, identifier)
       when is_binary(identifier) do
    normalize_identifier(channel.federated_source || channel_federation_id(channel.id)) ==
      normalize_identifier(identifier)
  end

  defp channel_matches_identifier?(_channel, _identifier), do: false

  defp local_resource_id(identifier, resource)
       when is_binary(identifier) and is_binary(resource) do
    with %URI{scheme: scheme, host: host, path: path}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <-
           URI.parse(identifier),
         true <- host_belongs_to_local_domain?(host),
         normalized_path <- String.trim_trailing(path || "", "/"),
         ["", "_arblarg", ^resource, id] <- String.split(normalized_path, "/"),
         {parsed_id, ""} <- Integer.parse(id) do
      parsed_id
    else
      _ -> nil
    end
  end

  defp local_resource_id(_identifier, _resource), do: nil

  defp host_belongs_to_local_domain?(host) when is_binary(host) do
    local_domain = normalize_domain(Elektrine.Messaging.Federation.local_domain())
    normalized_host = normalize_domain(host)

    normalized_host == local_domain or
      String.ends_with?(normalized_host, "." <> local_domain)
  end

  defp host_belongs_to_local_domain?(_host), do: false

  defp message_origin_domain(payload, fallback_domain)
       when is_map(payload) and is_binary(fallback_domain) do
    sender_domain =
      payload["sender"]
      |> actor_domain_from_payload()

    message_host = payload["id"] |> uri_host()

    cond do
      is_binary(sender_domain) and is_binary(message_host) and
          host_belongs_to_domain?(message_host, sender_domain) ->
        normalize_domain(sender_domain)

      is_binary(message_host) ->
        normalize_domain(message_host)

      true ->
        normalize_domain(fallback_domain)
    end
  end

  defp message_origin_domain(_payload, _fallback_domain), do: nil

  defp actor_domain_from_payload(%{} = actor) do
    normalize_domain(actor["domain"] || actor[:domain] || uri_host(actor["uri"] || actor[:uri]))
  end

  defp actor_domain_from_payload(_actor), do: nil

  defp normalize_identifier(identifier) when is_binary(identifier) do
    identifier
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp normalize_identifier(_identifier), do: nil

  defp normalize_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_domain(_value), do: nil

  defp host_belongs_to_domain?(host, domain)
       when is_binary(host) and is_binary(domain) do
    normalized_host = normalize_domain(host)
    normalized_domain = normalize_domain(domain)

    normalized_host == normalized_domain or
      String.ends_with?(normalized_host, "." <> normalized_domain)
  end

  defp host_belongs_to_domain?(_host, _domain), do: false

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
