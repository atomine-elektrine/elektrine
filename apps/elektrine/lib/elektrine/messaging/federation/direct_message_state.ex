defmodule Elektrine.Messaging.Federation.DirectMessageState do
  @moduledoc false

  import Ecto.Query, warn: false
  import Elektrine.Messaging.Federation.Utils

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Messaging.{ChatMessage, ChatMessages, Conversation, ConversationMember}
  alias Elektrine.Notifications
  alias Elektrine.Profiles
  alias Elektrine.Repo

  @remote_dm_source_prefix "arblarg:dm:"

  def resolve_outbound_dm_handle(%ChatMessage{} = message, nil) do
    case Repo.get(Conversation, message.conversation_id) do
      %Conversation{} = conversation ->
        case remote_dm_handle_from_source(conversation.federated_source) do
          handle when is_binary(handle) -> {:ok, handle}
          _ -> {:error, :invalid_remote_handle}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def resolve_outbound_dm_handle(_message, remote_handle) when is_binary(remote_handle) do
    case normalize_remote_dm_handle(remote_handle) do
      {:ok, recipient} -> {:ok, recipient.handle}
      error -> error
    end
  end

  def resolve_outbound_dm_handle(_message, _remote_handle), do: {:error, :invalid_remote_handle}

  def resolve_local_dm_recipient(recipient_payload, context)
      when is_map(recipient_payload) and is_map(context) do
    with {:ok, recipient} <-
           normalize_dm_actor_payload(recipient_payload, call(context, :local_domain, [])),
         {:ok, %User{} = local_user} <- resolve_local_recipient_user(recipient) do
      {:ok, local_user}
    else
      {:error, :user_not_found} -> {:error, :user_not_found}
      _ -> {:error, :invalid_event_payload}
    end
  end

  def resolve_local_dm_recipient(_recipient_payload, _context),
    do: {:error, :invalid_event_payload}

  def resolve_remote_dm_sender(sender_payload, remote_domain)
      when is_map(sender_payload) and is_binary(remote_domain) do
    normalized_remote_domain = String.downcase(remote_domain)

    with {:ok, sender} <- normalize_dm_actor_payload(sender_payload, normalized_remote_domain),
         true <- sender.domain == normalized_remote_domain do
      {:ok, sender}
    else
      false -> {:error, :origin_domain_mismatch}
      _ -> {:error, :invalid_event_payload}
    end
  end

  def resolve_remote_dm_sender(_sender_payload, _remote_domain),
    do: {:error, :invalid_event_payload}

  defp resolve_local_recipient_user(%{domain: domain, username: username})
       when is_binary(domain) and is_binary(username) do
    normalized_domain = String.downcase(domain)

    if normalized_domain == String.downcase(Elektrine.Messaging.Federation.local_domain()) do
      case Accounts.get_user_by_username(username) do
        %User{} = user -> {:ok, user}
        _ -> {:error, :user_not_found}
      end
    else
      case Profiles.get_verified_custom_domain(normalized_domain) do
        %{user: %{username: ^username} = user} -> {:ok, user}
        %{domain: ^normalized_domain} -> {:error, :user_not_found}
        _ -> {:error, :invalid_event_payload}
      end
    end
  end

  defp resolve_local_recipient_user(_recipient), do: {:error, :invalid_event_payload}

  def ensure_remote_dm_conversation(%User{} = local_user, remote_sender)
      when is_map(remote_sender) do
    remote_source = remote_dm_source(remote_sender)
    remote_sources = remote_dm_source_candidates(remote_sender)

    existing_remote_dm =
      from(c in Conversation,
        join: cm in ConversationMember,
        on: c.id == cm.conversation_id,
        where:
          c.type == "dm" and c.federated_source in ^remote_sources and
            cm.user_id == ^local_user.id and is_nil(cm.left_at),
        limit: 1
      )

    case Repo.one(existing_remote_dm) do
      %Conversation{} = conversation ->
        maybe_upgrade_remote_dm_source(conversation, remote_source)

      nil ->
        case Repo.transaction(fn ->
               {:ok, conversation} =
                 %Conversation{}
                 |> Conversation.dm_changeset(%{
                   creator_id: local_user.id,
                   name: "@" <> remote_sender.handle,
                   avatar_url: remote_sender.avatar_url,
                   federated_source: remote_source
                 })
                 |> Repo.insert()

               {:ok, _member} =
                 ConversationMember.add_member_changeset(conversation.id, local_user.id, "member")
                 |> Repo.insert()

               from(c in Conversation, where: c.id == ^conversation.id)
               |> Repo.update_all(set: [member_count: 1])

               conversation
             end) do
          {:ok, conversation} ->
            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "user:#{local_user.id}",
              {:added_to_conversation, %{conversation_id: conversation.id}}
            )

            {:ok, conversation}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def ensure_remote_dm_conversation(_local_user, _remote_sender),
    do: {:error, :invalid_event_payload}

  def upsert_remote_dm_message(
        %Conversation{} = conversation,
        message_payload,
        remote_domain,
        remote_sender,
        context
      )
      when is_map(message_payload) and is_binary(remote_domain) and is_map(remote_sender) and
             is_map(context) do
    federation_message_id = normalize_optional_string(message_payload["id"])
    attachments = call(context, :normalize_message_attachments, [message_payload])
    media_urls = Enum.map(attachments, & &1["url"])
    content = normalize_optional_string(message_payload["content"])

    cond do
      !is_binary(federation_message_id) ->
        {:error, :invalid_event_payload}

      !is_binary(content) and media_urls == [] ->
        {:error, :invalid_event_payload}

      true ->
        case Repo.get_by(ChatMessage,
               conversation_id: conversation.id,
               federated_source: federation_message_id
             ) do
          %ChatMessage{} ->
            {:ok, :duplicate}

          nil ->
            message_metadata = call(context, :attachment_storage_metadata, [attachments])

            attrs = %{
              conversation_id: conversation.id,
              sender_id: nil,
              content: content,
              message_type: normalize_message_type(message_payload["message_type"]),
              media_urls: media_urls,
              media_metadata:
                Map.put(
                  message_metadata,
                  "remote_sender",
                  remote_sender_metadata(remote_sender, message_payload["sender"])
                ),
              federated_source: federation_message_id,
              origin_domain: String.downcase(remote_domain),
              is_federated_mirror: true,
              edited_at: parse_datetime(message_payload["edited_at"])
            }

            with {:ok, inserted_message} <-
                   %ChatMessage{} |> ChatMessage.changeset(attrs) |> Repo.insert() do
              from(c in Conversation, where: c.id == ^conversation.id)
              |> Repo.update_all(set: [last_message_at: inserted_message.inserted_at])

              {:ok, inserted_message}
            end
        end
    end
  end

  def upsert_remote_dm_message(
        _conversation,
        _message_payload,
        _remote_domain,
        _remote_sender,
        _context
      ),
      do: {:error, :invalid_event_payload}

  def maybe_broadcast_remote_dm_message_created(
        _conversation,
        :duplicate,
        _local_user,
        _remote_sender,
        _context
      ),
      do: :ok

  def maybe_broadcast_remote_dm_message_created(
        %Conversation{} = conversation,
        %ChatMessage{} = message,
        %User{} = local_user,
        remote_sender,
        context
      )
      when is_map(remote_sender) and is_map(context) do
    decrypted =
      case ChatMessages.get_message_decrypted(message.id) do
        %ChatMessage{} = hydrated -> hydrated
        _ -> message
      end

    call(context, :broadcast_conversation_event, [conversation.id, {:new_chat_message, decrypted}])

    Elektrine.AppCache.invalidate_chat_cache(local_user.id)

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{local_user.id}",
      {:conversation_activity, %{conversation_id: conversation.id}}
    )

    maybe_notify_remote_dm_recipient(local_user, conversation, decrypted, remote_sender)
    :ok
  end

  def maybe_broadcast_remote_dm_message_created(
        _conversation,
        _message,
        _local_user,
        _remote_sender,
        _context
      ),
      do: :ok

  def dm_actor_payload(recipient) when is_map(recipient) do
    username = Map.get(recipient, :username) || Map.get(recipient, "username")
    domain = Map.get(recipient, :domain) || Map.get(recipient, "domain")
    handle = Map.get(recipient, :handle) || Map.get(recipient, "handle")
    display_name = Map.get(recipient, :display_name) || Map.get(recipient, "display_name")
    avatar_url = Map.get(recipient, :avatar_url) || Map.get(recipient, "avatar_url")

    uri =
      Map.get(recipient, :uri) || Map.get(recipient, "uri") || Map.get(recipient, :id) ||
        Map.get(recipient, "id") ||
        if(is_binary(username) and is_binary(domain), do: "https://#{domain}/users/#{username}")

    %{
      "id" => uri,
      "uri" => uri,
      "username" => username,
      "display_name" => display_name || username,
      "domain" => domain,
      "handle" => handle
    }
    |> maybe_put_optional_map_value("avatar_url", avatar_url)
  end

  def normalize_dm_actor_payload(payload, fallback_domain)
      when is_map(payload) and is_binary(fallback_domain) do
    normalized_fallback_domain = String.downcase(fallback_domain)
    raw_uri = normalize_optional_string(payload["uri"] || payload[:uri])
    raw_handle = normalize_optional_string(payload["handle"] || payload[:handle])
    raw_username = normalize_optional_string(payload["username"] || payload[:username])
    raw_domain = normalize_optional_string(payload["domain"] || payload[:domain])

    normalized_identity =
      cond do
        is_binary(raw_handle) ->
          normalize_remote_dm_handle(raw_handle)

        is_binary(raw_username) ->
          domain = raw_domain || normalized_fallback_domain
          normalize_remote_dm_handle("#{raw_username}@#{domain}")

        true ->
          {:error, :invalid_event_payload}
      end

    with {:ok, identity} <- normalized_identity,
         true <- valid_absolute_http_uri?(raw_uri) do
      {:ok,
       %{
         uri: raw_uri,
         username: identity.username,
         domain: identity.domain,
         handle: identity.handle,
         display_name:
           normalize_optional_string(payload["display_name"] || payload[:display_name]) ||
             identity.username,
         avatar_url:
           normalize_optional_string(
             payload["avatar_url"] || payload[:avatar_url] || payload["avatar"] ||
               payload[:avatar]
           )
       }}
    else
      false ->
        {:error, :invalid_event_payload}

      error ->
        error
    end
  end

  def normalize_dm_actor_payload(_payload, _fallback_domain),
    do: {:error, :invalid_event_payload}

  def normalize_remote_dm_handle(handle) when is_binary(handle) do
    normalized =
      handle
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    case Regex.run(~r/^([a-z0-9][a-z0-9_.-]{0,63})@([a-z0-9.-]+\.[a-z]{2,})$/, normalized) do
      [_, username, domain] ->
        {:ok, %{username: username, domain: domain, handle: "#{username}@#{domain}"}}

      _ ->
        {:error, :invalid_remote_handle}
    end
  end

  def normalize_remote_dm_handle(_handle), do: {:error, :invalid_remote_handle}

  def remote_dm_handle_from_source(source) when is_binary(source) do
    with remote_handle when is_binary(remote_handle) <- remote_dm_source_value(source),
         {:ok, recipient} <- normalize_remote_dm_handle(remote_handle) do
      recipient.handle
    else
      _ -> nil
    end
  end

  def remote_dm_handle_from_source(_source), do: nil

  def remote_dm_uri_from_source(source) when is_binary(source) do
    case String.split(source, "|", parts: 2) do
      [uri_source, _rest] ->
        uri_source
        |> String.replace_prefix(@remote_dm_source_prefix <> "uri:", "")
        |> URI.decode_www_form()
        |> normalize_optional_string()

      _ ->
        nil
    end
  end

  def remote_dm_uri_from_source(_source), do: nil

  def remote_dm_source(remote_sender) when is_map(remote_sender) do
    uri = Map.get(remote_sender, :uri) || Map.get(remote_sender, "uri")
    handle = Map.get(remote_sender, :handle) || Map.get(remote_sender, "handle")

    if is_binary(uri) and is_binary(handle) do
      @remote_dm_source_prefix <> "uri:" <> URI.encode_www_form(uri) <> "|handle:" <> handle
    else
      remote_dm_source(handle)
    end
  end

  def remote_dm_source(handle) when is_binary(handle) do
    @remote_dm_source_prefix <> "handle:" <> handle
  end

  def remote_dm_source(_handle), do: nil

  defp remote_dm_source_candidates(remote_sender) when is_map(remote_sender) do
    handle = Map.get(remote_sender, :handle) || Map.get(remote_sender, "handle")

    [
      remote_dm_source(remote_sender),
      remote_dm_source(handle),
      if(is_binary(handle), do: @remote_dm_source_prefix <> handle)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp remote_dm_source_candidates(_remote_sender), do: []

  defp remote_dm_source_value(source) do
    cond do
      !String.starts_with?(source, @remote_dm_source_prefix) ->
        nil

      String.starts_with?(source, @remote_dm_source_prefix <> "uri:") ->
        source
        |> String.split("|handle:", parts: 2)
        |> case do
          [_uri_source, handle] -> handle
          _ -> nil
        end

      String.starts_with?(source, @remote_dm_source_prefix <> "handle:") ->
        String.replace_prefix(source, @remote_dm_source_prefix <> "handle:", "")

      true ->
        String.replace_prefix(source, @remote_dm_source_prefix, "")
    end
  end

  defp maybe_upgrade_remote_dm_source(%Conversation{} = conversation, remote_source) do
    if is_binary(remote_source) and conversation.federated_source != remote_source do
      case conversation
           |> Conversation.changeset(%{federated_source: remote_source})
           |> Repo.update() do
        {:ok, updated_conversation} -> {:ok, updated_conversation}
        {:error, _reason} -> {:ok, conversation}
      end
    else
      {:ok, conversation}
    end
  end

  defp maybe_notify_remote_dm_recipient(
         %User{notify_on_direct_message: false},
         _conversation,
         _message,
         _remote_sender
       ),
       do: :ok

  defp maybe_notify_remote_dm_recipient(
         %User{} = local_user,
         %Conversation{} = conversation,
         %ChatMessage{} = message,
         remote_sender
       )
       when is_map(remote_sender) do
    title = "Message from @#{remote_sender.handle}"

    _ =
      Notifications.create_notification(%{
        user_id: local_user.id,
        actor_id: nil,
        type: "new_message",
        title: title,
        body: remote_dm_message_preview(message),
        url: Elektrine.Paths.chat_message_path(conversation.hash || conversation.id, message.id),
        source_type: "message",
        source_id: message.id,
        priority: "normal",
        metadata: %{"remote_sender" => remote_sender_metadata(remote_sender)}
      })

    :ok
  end

  defp maybe_notify_remote_dm_recipient(_local_user, _conversation, _message, _remote_sender),
    do: :ok

  defp remote_dm_message_preview(%ChatMessage{} = message) do
    cond do
      is_binary(normalize_optional_string(message.content)) ->
        message.content |> String.trim() |> String.slice(0, 140)

      (message.media_urls || []) != [] ->
        "Sent an attachment"

      true ->
        "New message"
    end
  end

  defp remote_dm_message_preview(_message), do: "New message"

  defp remote_sender_metadata(remote_sender, sender_payload \\ nil)

  defp remote_sender_metadata(remote_sender, sender_payload) when is_map(remote_sender) do
    base =
      case sender_payload do
        %{} = payload -> payload
        _ -> %{}
      end

    base
    |> maybe_put_optional_map_value(
      "id",
      Map.get(remote_sender, :uri) || Map.get(remote_sender, "uri")
    )
    |> maybe_put_optional_map_value(
      "uri",
      Map.get(remote_sender, :uri) || Map.get(remote_sender, "uri")
    )
    |> Map.put("username", remote_sender.username)
    |> Map.put("display_name", remote_sender.display_name || remote_sender.username)
    |> Map.put("domain", remote_sender.domain)
    |> Map.put("handle", remote_sender.handle)
    |> maybe_put_optional_map_value("avatar_url", remote_sender.avatar_url)
    |> maybe_put_optional_map_value("avatar", remote_sender.avatar_url)
  end

  defp remote_sender_metadata(_remote_sender, _sender_payload), do: %{}

  defp maybe_put_optional_map_value(map, _key, nil), do: map

  defp maybe_put_optional_map_value(map, key, value) when is_binary(value) do
    if Elektrine.Strings.present?(value), do: Map.put(map, key, value), else: map
  end

  defp maybe_put_optional_map_value(map, _key, _value), do: map

  defp valid_absolute_http_uri?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_absolute_http_uri?(_value), do: false

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_value), do: nil

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
