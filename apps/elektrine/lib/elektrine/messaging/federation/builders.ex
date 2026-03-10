defmodule Elektrine.Messaging.Federation.Builders do
  @moduledoc false

  import Ecto.Query, warn: false
  import Elektrine.Messaging.Federation.Utils

  alias Elektrine.Accounts.User
  alias Elektrine.Messaging.{
    ArblargSDK,
    ChatMessage,
    ChatMessageReaction,
    Conversation,
    ConversationMember,
    FederationOutboxEvent,
    Server,
    ServerMember
  }

  alias Elektrine.Messaging.Federation.{DirectMessageState, State}
  alias Elektrine.Repo

  @dm_message_create_event_type ArblargSDK.dm_message_create_event_type()

  def build_server_upsert_event(server_id, context) when is_integer(server_id) and is_map(context) do
    with %Server{} = server <- Repo.get(Server, server_id),
         false <- server.is_federated_mirror do
      channels =
        from(c in Conversation,
          where:
            c.server_id == ^server.id and c.type == "channel" and c.is_federated_mirror != true,
          order_by: [asc: c.channel_position, asc: c.inserted_at]
        )
        |> Repo.all()

      stream_id = server_stream_id(server.id)
      sequence = next_outbound_sequence(stream_id)

      {:ok,
       event_envelope(
         ArblargSDK.bootstrap_server_upsert_event_type(),
         stream_id,
         sequence,
         %{
           "server" => server_payload(server),
           "channels" => Enum.map(channels, &channel_payload/1)
         },
         context
       )}
    else
      nil -> {:error, :not_found}
      true -> {:error, :federated_mirror}
    end
  end

  def build_message_created_event(%ChatMessage{} = message, opts, context)
      when is_list(opts) and is_map(context) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, [:sender, conversation: [:server]])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        stream_id = channel_stream_id(conversation.id)
        sequence = next_outbound_sequence(stream_id)
        refs = event_refs_payload(server, conversation)

        {:ok,
         event_envelope(
           "message.create",
           stream_id,
           sequence,
           %{"refs" => refs, "message" => event_message_payload(message)},
           context
         )}
    end
  end

  def build_dm_message_created_event(%ChatMessage{} = message, remote_handle, context)
      when is_binary(remote_handle) and is_map(context) do
    message = Repo.preload(message, [:sender, :conversation])
    conversation = message.conversation

    with {:ok, recipient} <- DirectMessageState.normalize_remote_dm_handle(remote_handle),
         %Conversation{} <- conversation,
         true <- conversation.type == "dm",
         true <- is_integer(message.sender_id),
         %User{} = sender <- message.sender,
         conversation_handle when is_binary(conversation_handle) <-
           DirectMessageState.remote_dm_handle_from_source(conversation.federated_source),
         true <- conversation_handle == recipient.handle do
      stream_id = dm_stream_id(conversation.id)
      sequence = next_outbound_sequence(stream_id)
      dm_id = dm_federation_id(conversation.id)
      sender_data = sender_payload(sender)

      {:ok,
       event_envelope(
         @dm_message_create_event_type,
         stream_id,
         sequence,
         %{
           "dm" => %{
             "id" => dm_id,
             "sender" => sender_data,
             "recipient" => DirectMessageState.dm_actor_payload(recipient)
           },
           "message" => %{
             "id" => message.federated_source || message_federation_id(message.id),
             "dm_id" => dm_id,
             "content" => message.content || "",
             "message_type" => message.message_type || "text",
             "attachments" => attachment_payloads(message),
             "created_at" => format_created_at(message.inserted_at),
             "edited_at" => format_created_at(message.edited_at),
             "sender" => sender_data
           }
         },
         context
       )}
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_event_payload}
      _ -> {:error, :unsupported_conversation_type}
    end
  end

  def build_message_updated_event(%ChatMessage{} = message, opts, context)
      when is_list(opts) and is_map(context) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, [:sender, conversation: [:server]])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        stream_id = channel_stream_id(conversation.id)
        sequence = next_outbound_sequence(stream_id)
        refs = event_refs_payload(server, conversation)

        {:ok,
         event_envelope(
           "message.update",
           stream_id,
           sequence,
           %{"refs" => refs, "message" => event_message_payload(message)},
           context
         )}
    end
  end

  def build_message_deleted_event(%ChatMessage{} = message, opts, context)
      when is_list(opts) and is_map(context) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, conversation: [:server])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        stream_id = channel_stream_id(conversation.id)
        sequence = next_outbound_sequence(stream_id)
        refs = event_refs_payload(server, conversation)

        {:ok,
         event_envelope(
           "message.delete",
           stream_id,
           sequence,
           %{
             "refs" => refs,
             "message_id" => message.federated_source || message_federation_id(message.id),
             "deleted_at" => format_created_at(message.deleted_at || DateTime.utc_now())
           },
           context
         )}
    end
  end

  def build_reaction_added_event(%ChatMessage{} = message, %ChatMessageReaction{} = reaction, opts, context)
      when is_list(opts) and is_map(context) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, conversation: [:server])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      is_nil(reaction.user_id) ->
        {:error, :unsupported_reaction_actor}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        user = Repo.get(User, reaction.user_id)

        if is_nil(user) do
          {:error, :not_found}
        else
          stream_id = channel_stream_id(conversation.id)
          sequence = next_outbound_sequence(stream_id)
          refs = event_refs_payload(server, conversation)

          {:ok,
           event_envelope(
             "reaction.add",
             stream_id,
             sequence,
             %{
               "refs" => refs,
               "message_id" => message.federated_source || message_federation_id(message.id),
               "reaction" => %{"emoji" => reaction.emoji, "actor" => sender_payload(user)}
             },
             context
           )}
        end
    end
  end

  def build_reaction_removed_event(%ChatMessage{} = message, user_id, emoji, opts, context)
      when is_integer(user_id) and is_list(opts) and is_map(context) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, conversation: [:server])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        user = Repo.get(User, user_id)

        if is_nil(user) do
          {:error, :not_found}
        else
          stream_id = channel_stream_id(conversation.id)
          sequence = next_outbound_sequence(stream_id)
          refs = event_refs_payload(server, conversation)

          {:ok,
           event_envelope(
             "reaction.remove",
             stream_id,
             sequence,
             %{
               "refs" => refs,
               "message_id" => message.federated_source || message_federation_id(message.id),
               "reaction" => %{"emoji" => emoji, "actor" => sender_payload(user)}
             },
             context
           )}
        end
    end
  end

  def build_read_cursor_event(conversation_id, user_id, message_id, read_at, context)
      when is_integer(conversation_id) and is_integer(user_id) and is_integer(message_id) and
             is_map(context) do
    conversation = Repo.get(Conversation, conversation_id) |> Repo.preload(:server)
    message = Repo.get(ChatMessage, message_id)
    user = Repo.get(User, user_id)
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) or is_nil(message) or is_nil(user) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      message.conversation_id != conversation.id ->
        {:error, :invalid_event_payload}

      true ->
        stream_id = outbound_channel_stream_id(conversation)
        sequence = next_outbound_sequence(stream_id)
        refs = event_refs_payload(server, conversation)
        target_domains = target_domains_for_server(server, context)

        {:ok,
         event_envelope(
           "read.cursor",
           stream_id,
           sequence,
           %{
             "refs" => refs,
             "read_through_message_id" =>
               message.federated_source || message_federation_id(message.id),
             "actor" => sender_payload(user),
             "read_through_sequence" => read_cursor_sequence_for_message(stream_id, message),
             "read_at" => format_created_at(read_at || DateTime.utc_now())
           },
           context
         ), target_domains}
    end
  end

  def build_membership_upsert_event(conversation_id, user_id, state, role, context)
      when is_integer(conversation_id) and is_integer(user_id) and is_binary(state) and
             is_binary(role) and is_map(context) do
    conversation = Repo.get(Conversation, conversation_id) |> Repo.preload(:server)
    user = Repo.get(User, user_id)
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) or is_nil(user) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror ->
        {:error, :federated_mirror}

      true ->
        stream_id = outbound_channel_stream_id(conversation)
        sequence = next_outbound_sequence(stream_id)
        refs = event_refs_payload(server, conversation)
        target_domains = target_domains_for_server(server, context)
        joined_at = active_membership_joined_at(conversation.id, user.id)

        {:ok,
         event_envelope(
           "membership.upsert",
           stream_id,
           sequence,
           %{
             "refs" => refs,
             "membership" => %{
               "actor" => sender_payload(user),
               "role" => role,
               "state" => state,
               "joined_at" => call(context, :maybe_iso8601, [joined_at]),
               "updated_at" =>
                 DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
               "metadata" => %{}
             }
           },
           context
         ), target_domains}
    end
  end

  def build_invite_upsert_event(
        conversation_id,
        target_user_id,
        actor_user_id,
        state,
        role,
        metadata,
        context
      )
      when is_integer(conversation_id) and is_integer(target_user_id) and
             is_integer(actor_user_id) and is_binary(state) and is_binary(role) and
             is_map(metadata) and is_map(context) do
    conversation = Repo.get(Conversation, conversation_id) |> Repo.preload(:server)
    target_user = Repo.get(User, target_user_id)
    actor_user = Repo.get(User, actor_user_id)
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) or is_nil(target_user) or is_nil(actor_user) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror ->
        {:error, :federated_mirror}

      state not in ["pending", "accepted", "declined", "revoked"] ->
        {:error, :invalid_event_payload}

      true ->
        stream_id = outbound_channel_stream_id(conversation)
        sequence = next_outbound_sequence(stream_id)
        refs = event_refs_payload(server, conversation)
        target_domains = target_domains_for_server(server, context)
        timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

        {:ok,
         event_envelope(
           "invite.upsert",
           stream_id,
           sequence,
           %{
             "refs" => refs,
             "invite" => %{
               "actor" => sender_payload(actor_user),
               "target" => sender_payload(target_user),
               "role" => role,
               "state" => state,
               "invited_at" => DateTime.to_iso8601(timestamp),
               "updated_at" => DateTime.to_iso8601(timestamp),
               "metadata" => metadata
             }
           },
           context
         ), target_domains}
    end
  end

  def build_ban_upsert_event(
        conversation_id,
        target_user_id,
        actor_user_id,
        state,
        reason,
        expires_at,
        metadata,
        context
      )
      when is_integer(conversation_id) and is_integer(target_user_id) and
             is_integer(actor_user_id) and is_binary(state) and is_map(metadata) and
             is_map(context) do
    conversation = Repo.get(Conversation, conversation_id) |> Repo.preload(:server)
    target_user = Repo.get(User, target_user_id)
    actor_user = Repo.get(User, actor_user_id)
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) or is_nil(target_user) or is_nil(actor_user) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror ->
        {:error, :federated_mirror}

      state not in ["active", "lifted"] ->
        {:error, :invalid_event_payload}

      true ->
        stream_id = outbound_channel_stream_id(conversation)
        sequence = next_outbound_sequence(stream_id)
        refs = event_refs_payload(server, conversation)
        target_domains = target_domains_for_server(server, context)
        timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

        {:ok,
         event_envelope(
           "ban.upsert",
           stream_id,
           sequence,
           %{
             "refs" => refs,
             "ban" => %{
               "actor" => sender_payload(actor_user),
               "target" => sender_payload(target_user),
               "state" => state,
               "reason" => call(context, :normalize_optional_string, [reason]),
               "banned_at" => DateTime.to_iso8601(timestamp),
               "updated_at" => DateTime.to_iso8601(timestamp),
               "expires_at" => call(context, :maybe_iso8601, [expires_at]),
               "metadata" => metadata
             }
           },
           context
         ), target_domains}
    end
  end

  def build_typing_ephemeral_item(conversation_id, user_id, mode, context)
      when mode in [:start, :stop] and is_integer(conversation_id) and is_integer(user_id) and
             is_map(context) do
    conversation = Repo.get(Conversation, conversation_id) |> Repo.preload(:server)
    user = Repo.get(User, user_id)
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) or is_nil(user) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      true ->
        timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

        payload = %{
          "refs" => event_refs_payload(server, conversation),
          "actor" => sender_payload(user)
        }

        payload =
          case mode do
            :start ->
              payload
              |> Map.put("started_at", DateTime.to_iso8601(timestamp))
              |> Map.put("ttl_ms", 3_000)

            :stop ->
              Map.put(payload, "stopped_at", DateTime.to_iso8601(timestamp))
          end

        event_type = if mode == :start, do: "typing.start", else: "typing.stop"

        {:ok, ephemeral_item(event_type, payload, context), target_domains_for_server(server, context)}
    end
  end

  def build_presence_ephemeral_item(server_id, user_id, status, activities, context)
      when is_integer(server_id) and is_integer(user_id) and is_binary(status) and is_map(context) do
    server = Repo.get(Server, server_id)
    user = Repo.get(User, user_id)

    if is_nil(server) or is_nil(user) do
      {:error, :not_found}
    else
      ttl_ms = call(context, :presence_ttl_seconds, []) * 1_000

      payload = %{
        "refs" => %{"server_id" => server.federation_id || server_federation_id(server.id)},
        "presence" => %{
          "actor" => sender_payload(user),
          "status" => status,
          "updated_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "activities" => State.normalize_presence_activities(activities),
          "ttl_ms" => ttl_ms
        }
      }

      {:ok, ephemeral_item("presence.update", payload, context), target_domains_for_server(server, context)}
    end
  end

  def event_envelope(event_type, stream_id, sequence, data, context)
      when is_binary(event_type) and is_binary(stream_id) and is_integer(sequence) and
             is_map(data) and is_map(context) do
    unsigned = %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "event_id" => Ecto.UUID.generate(),
      "event_type" => event_type,
      "origin_domain" => call(context, :local_domain, []),
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "idempotency_key" => Ecto.UUID.generate(),
      "payload" => data
    }

    {key_id, signing_material} = call(context, :local_event_signing_material, [])
    ArblargSDK.sign_event_envelope(unsigned, key_id, signing_material)
  end

  def active_server_ids_for_user(user_id) when is_integer(user_id) do
    from(sm in ServerMember,
      where: sm.user_id == ^user_id and is_nil(sm.left_at),
      select: sm.server_id
    )
    |> Repo.all()
  end

  def active_server_ids_for_user(_user_id), do: []

  defp ephemeral_item(event_type, payload, context)
       when is_binary(event_type) and is_map(payload) and is_map(context) do
    %{
      "event_type" => event_type,
      "origin_domain" => call(context, :local_domain, []),
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "payload" => payload
    }
  end

  defp read_cursor_sequence_for_message(stream_id, %ChatMessage{} = message)
       when is_binary(stream_id) do
    federation_message_id = message.federated_source || message_federation_id(message.id)

    from(o in FederationOutboxEvent,
      where: o.stream_id == ^stream_id and o.event_type == "message.create",
      where: fragment("?->'payload'->'message'->>'id' = ?", o.payload, ^federation_message_id),
      select: o.sequence,
      limit: 1
    )
    |> Repo.one()
  end

  defp read_cursor_sequence_for_message(_stream_id, _message), do: nil

  defp outbound_channel_stream_id(%Conversation{} = conversation) do
    "channel:" <> (conversation.federated_source || channel_federation_id(conversation.id))
  end

  defp outbound_channel_stream_id(conversation_id) when is_integer(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{} = conversation -> outbound_channel_stream_id(conversation)
      _ -> channel_stream_id(conversation_id)
    end
  end

  defp outbound_channel_stream_id(_conversation), do: nil

  defp target_domains_for_server(%Server{is_federated_mirror: true, origin_domain: origin_domain}, _context)
       when is_binary(origin_domain) do
    [String.downcase(origin_domain)]
  end

  defp target_domains_for_server(%Server{}, context) do
    call(context, :outgoing_peers, [])
    |> Enum.map(&String.downcase(&1.domain))
    |> Enum.uniq()
  end

  defp target_domains_for_server(_server, _context), do: []

  defp active_membership_joined_at(conversation_id, user_id)
       when is_integer(conversation_id) and is_integer(user_id) do
    active_joined_at =
      from(cm in ConversationMember,
        where:
          cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and is_nil(cm.left_at),
        limit: 1,
        select: cm.joined_at
      )
      |> Repo.one()

    case active_joined_at do
      %DateTime{} = joined_at ->
        joined_at

      _ ->
        from(cm in ConversationMember,
          where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id,
          limit: 1,
          select: cm.joined_at
        )
        |> Repo.one()
    end
  end

  defp active_membership_joined_at(_conversation_id, _user_id), do: nil

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
