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
    FederationCallSession,
    FederationOutboxEvent,
    Server,
    ServerMember
  }

  alias Elektrine.Messaging.Federation.{DirectMessageState, State, Visibility, VoiceCalls}
  alias Elektrine.Repo

  @dm_message_create_event_type ArblargSDK.dm_message_create_event_type()
  @dm_call_invite_event_type ArblargSDK.dm_call_invite_event_type()
  @dm_call_accept_event_type ArblargSDK.dm_call_accept_event_type()
  @dm_call_reject_event_type ArblargSDK.dm_call_reject_event_type()
  @dm_call_end_event_type ArblargSDK.dm_call_end_event_type()
  @dm_call_signal_event_type ArblargSDK.dm_call_signal_event_type()

  def build_server_upsert_event(server_id, context)
      when is_integer(server_id) and is_map(context) do
    with %Server{} = server <- Repo.get(Server, server_id),
         false <- server.is_federated_mirror,
         true <- server.is_public == true do
      channels = Visibility.public_bootstrap_channels(server)

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
      false -> {:error, :not_public}
    end
  end

  def build_message_created_event(%ChatMessage{} = message, context) when is_map(context) do
    message = Repo.preload(message, [:sender, conversation: [:server]])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      true ->
        stream_id = outbound_channel_stream_id(conversation)
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
         origin_domain = preferred_dm_origin_domain_for_user(sender),
         conversation_handle when is_binary(conversation_handle) <-
           DirectMessageState.remote_dm_handle_from_source(conversation.federated_source),
         true <- conversation_handle == recipient.handle do
      stream_id = dm_stream_id(conversation.id, domain: origin_domain)
      sequence = next_outbound_sequence(stream_id)
      dm_id = dm_federation_id(conversation.id, domain: origin_domain)
      sender_data = sender_payload(sender, domain: origin_domain)

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
             "id" =>
               message.federated_source ||
                 message_federation_id(message.id, domain: origin_domain),
             "dm_id" => dm_id,
             "content" => message.content || "",
             "message_type" => message.message_type || "text",
             "attachments" => attachment_payloads(message),
             "created_at" => format_created_at(message.inserted_at),
             "edited_at" => format_created_at(message.edited_at),
             "sender" => sender_data
           }
         },
         context,
         origin_domain: origin_domain
       )}
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_event_payload}
      _ -> {:error, :unsupported_conversation_type}
    end
  end

  def build_dm_call_invite_event(session_id, context)
      when is_integer(session_id) and is_map(context) do
    with %FederationCallSession{} = session <- VoiceCalls.get_session(session_id),
         %Conversation{} = conversation <- session.conversation,
         %User{} = local_user <- session.local_user do
      origin_domain = dm_event_origin_domain(session, local_user)
      stream_id = dm_stream_id(conversation.id, domain: origin_domain)
      sequence = next_outbound_sequence(stream_id)
      dm_payload = dm_call_context_payload(session, local_user)

      payload = %{
        "dm" => dm_payload,
        "call" => %{
          "id" => session.federated_call_id,
          "dm_id" => dm_payload["id"],
          "call_type" => session.call_type,
          "actor" => sender_payload(local_user, domain: origin_domain),
          "initiated_at" => format_created_at(session.inserted_at),
          "metadata" => session.metadata || %{}
        }
      }

      with :ok <- ArblargSDK.validate_event_payload(@dm_call_invite_event_type, payload) do
        {:ok,
         event_envelope(
           @dm_call_invite_event_type,
           stream_id,
           sequence,
           payload,
           context,
           origin_domain: origin_domain
         ), [session.remote_domain]}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def build_dm_call_accept_event(session_id, context)
      when is_integer(session_id) and is_map(context) do
    build_dm_call_terminal_event(
      session_id,
      @dm_call_accept_event_type,
      %{
        "accepted_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      },
      context
    )
  end

  def build_dm_call_reject_event(session_id, context)
      when is_integer(session_id) and is_map(context) do
    build_dm_call_terminal_event(
      session_id,
      @dm_call_reject_event_type,
      %{
        "rejected_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "reason" => get_in(VoiceCalls.get_session(session_id) || %{}, [:metadata, "reason"])
      },
      context
    )
  end

  def build_dm_call_end_event(session_id, context)
      when is_integer(session_id) and is_map(context) do
    build_dm_call_terminal_event(
      session_id,
      @dm_call_end_event_type,
      %{
        "ended_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "reason" => get_in(VoiceCalls.get_session(session_id) || %{}, [:metadata, "reason"])
      },
      context
    )
  end

  def build_dm_call_signal_ephemeral_item(
        session_id,
        actor_user_id,
        kind,
        signal_payload,
        context
      )
      when is_integer(session_id) and is_integer(actor_user_id) and is_binary(kind) and
             is_map(signal_payload) and is_map(context) do
    with %FederationCallSession{} = session <- VoiceCalls.get_session(session_id),
         %Conversation{} = _conversation <- session.conversation,
         %User{} = local_user <- session.local_user,
         true <- local_user.id == actor_user_id do
      origin_domain = dm_event_origin_domain(session, local_user)

      payload = %{
        "dm" => dm_call_context_payload(session, local_user),
        "call_id" => session.federated_call_id,
        "actor" => sender_payload(local_user, domain: origin_domain),
        "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "signal" => %{
          "kind" => kind,
          "payload" => signal_payload
        }
      }

      with :ok <- ArblargSDK.validate_event_payload(@dm_call_signal_event_type, payload) do
        {:ok,
         ephemeral_item(@dm_call_signal_event_type, payload, context,
           origin_domain: origin_domain
         ), [session.remote_domain]}
      end
    else
      false -> {:error, :unauthorized}
      _ -> {:error, :not_found}
    end
  end

  def build_message_updated_event(%ChatMessage{} = message, context) when is_map(context) do
    message = Repo.preload(message, [:sender, conversation: [:server]])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      true ->
        stream_id = outbound_channel_stream_id(conversation)
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

  def build_message_deleted_event(%ChatMessage{} = message, context) when is_map(context) do
    message = Repo.preload(message, conversation: [:server])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      true ->
        stream_id = outbound_channel_stream_id(conversation)
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

  def build_reaction_added_event(
        %ChatMessage{} = message,
        %ChatMessageReaction{} = reaction,
        context
      )
      when is_map(context) do
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

      true ->
        user = Repo.get(User, reaction.user_id)

        if is_nil(user) do
          {:error, :not_found}
        else
          stream_id = outbound_channel_stream_id(conversation)
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

  def build_reaction_removed_event(%ChatMessage{} = message, user_id, emoji, context)
      when is_integer(user_id) and is_map(context) do
    message = Repo.preload(message, conversation: [:server])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      true ->
        user = Repo.get(User, user_id)

        if is_nil(user) do
          {:error, :not_found}
        else
          stream_id = outbound_channel_stream_id(conversation)
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
        target_domains = target_domains_for_conversation(conversation, context)

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

      true ->
        stream_id = outbound_channel_stream_id(conversation)
        sequence = next_outbound_sequence(stream_id)
        refs = event_refs_payload(server, conversation)
        target_domains = target_domains_for_conversation(conversation, context)
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
        build_invite_upsert_event_for_target_payload(
          conversation_id,
          sender_payload(target_user),
          actor_user_id,
          state,
          role,
          metadata,
          context
        )
    end
  end

  def build_invite_upsert_event_for_target_payload(
        conversation_id,
        target_payload,
        actor_user_id,
        state,
        role,
        metadata,
        context
      )
      when is_integer(conversation_id) and is_map(target_payload) and
             is_integer(actor_user_id) and is_binary(state) and is_binary(role) and
             is_map(metadata) and is_map(context) do
    conversation = Repo.get(Conversation, conversation_id) |> Repo.preload(:server)
    actor_user = Repo.get(User, actor_user_id)
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) or is_nil(actor_user) ->
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
        target_domains = target_domains_for_invite_target(conversation, target_payload, context)
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
               "target" => target_payload,
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

        target_domains =
          target_domains_for_invite_target(conversation, sender_payload(target_user), context)

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

        {:ok, ephemeral_item(event_type, payload, context),
         target_domains_for_conversation(conversation, context)}
    end
  end

  def build_presence_ephemeral_item(user_id, status, activities, context)
      when is_integer(user_id) and is_binary(status) and is_map(context) do
    user = Repo.get(User, user_id)

    if is_nil(user) do
      {:error, :not_found}
    else
      ttl_ms = call(context, :presence_ttl_seconds, []) * 1_000

      payload = %{
        "presence" => %{
          "actor" => sender_payload(user),
          "status" => status,
          "updated_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "activities" => State.normalize_presence_activities(activities),
          "ttl_ms" => ttl_ms
        }
      }

      {:ok, ephemeral_item("presence.update", payload, context)}
    end
  end

  def build_room_presence_ephemeral_item(conversation_id, user_id, status, activities, context)
      when is_integer(conversation_id) and is_integer(user_id) and is_binary(status) and
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
        ttl_ms = call(context, :presence_ttl_seconds, []) * 1_000

        payload = %{
          "refs" => event_refs_payload(server, conversation),
          "presence" => %{
            "actor" => sender_payload(user),
            "status" => status,
            "updated_at" =>
              DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
            "activities" => State.normalize_presence_activities(activities),
            "ttl_ms" => ttl_ms
          }
        }

        {:ok, ephemeral_item("presence.update", payload, context),
         target_domains_for_conversation(conversation, context)}
    end
  end

  def build_extension_event(conversation_id, actor_user_id, event_type, payload, context)
      when is_integer(conversation_id) and is_integer(actor_user_id) and is_binary(event_type) and
             is_map(payload) and is_map(context) do
    conversation = Repo.get(Conversation, conversation_id) |> Repo.preload(:server)
    actor_user = Repo.get(User, actor_user_id)
    server = if conversation, do: conversation.server, else: nil
    canonical_event_type = ArblargSDK.canonical_event_type(event_type)

    normalized_event_type =
      Map.get(ArblargSDK.schema_bindings(), canonical_event_type, canonical_event_type)

    cond do
      is_nil(conversation) or is_nil(server) or is_nil(actor_user) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      canonical_event_type not in shared_governance_extension_event_types() ->
        {:error, :unsupported_event_type}

      true ->
        stream_id = outbound_channel_stream_id(conversation)
        sequence = next_outbound_sequence(stream_id)
        refs = event_refs_payload(server, conversation)

        extension_payload =
          normalized_event_type
          |> extension_payload_for_event_type(
            payload,
            server,
            conversation,
            actor_user
          )
          |> Map.put("refs", refs)

        with :ok <- ArblargSDK.validate_event_payload(canonical_event_type, extension_payload) do
          {:ok,
           event_envelope(
             canonical_event_type,
             stream_id,
             sequence,
             extension_payload,
             context
           ), target_domains_for_conversation(conversation, context), canonical_event_type,
           extension_payload}
        end
    end
  end

  def event_envelope(event_type, stream_id, sequence, data, context, opts \\ [])
      when is_binary(event_type) and is_binary(stream_id) and is_integer(sequence) and
             is_map(data) and is_map(context) do
    unsigned = %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "event_id" => Ecto.UUID.generate(),
      "event_type" => event_type,
      "origin_domain" => Keyword.get(opts, :origin_domain, call(context, :local_domain, [])),
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

  defp ephemeral_item(event_type, payload, context, opts \\ [])
       when is_binary(event_type) and is_map(payload) and is_map(context) do
    %{
      "event_type" => event_type,
      "origin_domain" => Keyword.get(opts, :origin_domain, call(context, :local_domain, [])),
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

  defp target_domains_for_conversation(%Conversation{} = conversation, context)
       when is_map(context) do
    Visibility.target_domains_for_room(conversation)
  end

  defp target_domains_for_conversation(_conversation, _context), do: []

  defp build_dm_call_terminal_event(session_id, event_type, extra_fields, context)
       when is_integer(session_id) and is_binary(event_type) and is_map(extra_fields) and
              is_map(context) do
    with %FederationCallSession{} = session <- VoiceCalls.get_session(session_id),
         %Conversation{} = conversation <- session.conversation,
         %User{} = local_user <- session.local_user do
      origin_domain = dm_event_origin_domain(session, local_user)
      stream_id = dm_stream_id(conversation.id, domain: origin_domain)
      sequence = next_outbound_sequence(stream_id)
      dm_payload = dm_call_context_payload(session, local_user)

      payload =
        %{
          "dm" => dm_payload,
          "call_id" => session.federated_call_id,
          "actor" => sender_payload(local_user, domain: origin_domain),
          "metadata" => session.metadata || %{}
        }
        |> Map.merge(
          Enum.reject(extra_fields, fn {_key, value} -> is_nil(value) end)
          |> Map.new()
        )

      with :ok <- ArblargSDK.validate_event_payload(event_type, payload) do
        {:ok,
         event_envelope(
           event_type,
           stream_id,
           sequence,
           payload,
           context,
           origin_domain: origin_domain
         ), [session.remote_domain]}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp dm_call_context_payload(%FederationCallSession{} = session, %User{} = local_user) do
    origin_domain = dm_event_origin_domain(session, local_user)
    local_actor = sender_payload(local_user, domain: origin_domain)

    if local_dm_origin_domain?(session.origin_domain, local_user) do
      %{
        "id" => dm_federation_id(session.conversation_id, domain: origin_domain),
        "sender" => local_actor,
        "recipient" => normalize_remote_actor_payload(session.remote_actor, session.remote_handle)
      }
    else
      %{
        "id" => dm_federation_id(session.conversation_id, domain: origin_domain),
        "sender" => normalize_remote_actor_payload(session.remote_actor, session.remote_handle),
        "recipient" => local_actor
      }
    end
  end

  defp dm_event_origin_domain(%FederationCallSession{}, %User{} = local_user) do
    preferred_dm_origin_domain_for_user(local_user)
  end

  defp local_dm_origin_domain?(origin_domain, %User{} = local_user)
       when is_binary(origin_domain) do
    normalized_origin = String.downcase(origin_domain)

    normalized_origin == String.downcase(Elektrine.Messaging.Federation.local_domain()) or
      normalized_origin == String.downcase(preferred_dm_origin_domain_for_user(local_user))
  end

  defp local_dm_origin_domain?(_, _), do: false

  defp normalize_remote_actor_payload(actor, remote_handle) when is_map(actor) do
    base =
      actor
      |> Enum.into(%{}, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)

    case base["handle"] || remote_handle do
      handle when is_binary(handle) -> Map.put(base, "handle", handle)
      _ -> base
    end
  end

  defp normalize_remote_actor_payload(_actor, remote_handle) when is_binary(remote_handle) do
    case DirectMessageState.normalize_remote_dm_handle(remote_handle) do
      {:ok, recipient} -> DirectMessageState.dm_actor_payload(recipient)
      _ -> %{"handle" => remote_handle}
    end
  end

  defp normalize_remote_actor_payload(_actor, _remote_handle), do: %{}

  defp target_domains_for_invite_target(%Conversation{} = conversation, target_payload, context)
       when is_map(target_payload) and is_map(context) do
    Visibility.target_domains_for_invite(conversation, target_payload)
  end

  defp target_domains_for_invite_target(%Conversation{} = conversation, _target_payload, context),
    do: target_domains_for_conversation(conversation, context)

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

  defp shared_governance_extension_event_types do
    [
      ArblargSDK.canonical_event_type("role.upsert"),
      ArblargSDK.canonical_event_type("role.assignment.upsert"),
      ArblargSDK.canonical_event_type("permission.overwrite.upsert"),
      ArblargSDK.canonical_event_type("thread.upsert"),
      ArblargSDK.canonical_event_type("thread.archive"),
      ArblargSDK.canonical_event_type("moderation.action.recorded")
    ]
  end

  defp extension_payload_for_event_type(event_type, payload, server, conversation, actor_user)
       when is_binary(event_type) and is_map(payload) do
    base_payload =
      payload
      |> Map.put("server", Map.get(payload, "server", server_payload(server)))
      |> Map.put("channel", Map.get(payload, "channel", channel_payload(conversation)))

    case event_type do
      event_type
      when event_type in [
             "role.upsert",
             "role.assignment.upsert",
             "permission.overwrite.upsert"
           ] ->
        Map.put_new(base_payload, "actor", sender_payload(actor_user))

      "thread.upsert" ->
        update_in(base_payload["thread"], fn
          %{} = thread -> Map.put_new(thread, "owner", sender_payload(actor_user))
          other -> other
        end)

      "thread.archive" ->
        Map.put_new(base_payload, "actor", sender_payload(actor_user))

      "moderation.action.recorded" ->
        update_in(base_payload["action"], fn
          %{} = action -> Map.put_new(action, "actor", sender_payload(actor_user))
          other -> other
        end)

      _ ->
        base_payload
    end
  end

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
