defmodule Elektrine.Messaging.FederationDMTest do
  use Elektrine.DataCase, async: false

  import Ecto.Query

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging

  alias Elektrine.Messaging.{
    ArblargSDK,
    ChatMessage,
    Federation
  }

  alias Elektrine.Messaging.ChatConversation, as: Conversation
  alias Elektrine.Messaging.ChatConversationMember, as: ConversationMember
  alias Elektrine.Repo

  describe "cross-instance DMs (Arblarg)" do
    setup do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [
            %{
              domain: "remote.example",
              base_url: "https://remote.example",
              shared_secret: "dm-secret",
              allow_incoming: true,
              allow_outgoing: true,
              supported_event_types: [ArblargSDK.dm_message_create_event_type()]
            }
          ]
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      :ok
    end

    test "publishes dm.message.create to only the target domain" do
      dm_event_type = ArblargSDK.dm_message_create_event_type()
      message = %ChatMessage{id: 1}
      parent = self()

      context = %{
        enabled?: fn -> true end,
        resolve_outbound_dm_handle: fn ^message, _remote_handle ->
          {:ok, "alice@remote.example"}
        end,
        normalize_remote_dm_handle: fn
          "alice@remote.example" ->
            {:ok, %{handle: "alice@remote.example", domain: "remote.example"}}

          _handle ->
            {:error, :invalid_handle}
        end,
        outgoing_peer: fn
          "remote.example" ->
            %{
              domain: "remote.example",
              supported_event_types: [dm_event_type],
              features: %{"supported_event_types" => [dm_event_type]}
            }

          _domain ->
            nil
        end,
        build_dm_message_created_event: fn ^message, "alice@remote.example" ->
          {:ok,
           %{
             "event_id" => "evt-1",
             "event_type" => dm_event_type,
             "payload" => %{
               "dm" => %{"recipient" => %{"handle" => "alice@remote.example"}}
             }
           }}
        end,
        enqueue_outbox_event: fn event, target_domains ->
          send(parent, {:enqueue_dm_event, event, target_domains})
          :ok
        end
      }

      assert :ok =
               Elektrine.Messaging.Federation.Publisher.publish_dm_message_created(
                 message,
                 nil,
                 context
               )

      assert_receive {:enqueue_dm_event, event, ["remote.example"]}
      assert event["event_type"] == dm_event_type
      assert get_in(event, ["payload", "dm", "recipient", "handle"]) == "alice@remote.example"
    end

    test "applies inbound dm.message.create and creates a federated DM conversation" do
      recipient = AccountsFixtures.user_fixture()
      remote_domain = "remote.example"
      local_domain = Federation.local_domain()
      dm_id = "https://remote.example/_arblarg/dms/alice-#{recipient.id}"
      stream_id = "dm:#{dm_id}"

      message_federation_id =
        "https://remote.example/_arblarg/messages/#{Ecto.UUID.generate()}"

      event =
        signed_event(
          ArblargSDK.dm_message_create_event_type(),
          remote_domain,
          stream_id,
          1,
          %{
            "dm" => %{
              "id" => dm_id,
              "sender" =>
                canonical_actor("alice", remote_domain,
                  display_name: "Alice Remote",
                  uri: "https://remote.example/users/alice"
                ),
              "recipient" =>
                canonical_actor(recipient.username, local_domain,
                  uri: "https://#{local_domain}/users/#{recipient.username}"
                )
            },
            "message" => %{
              "id" => message_federation_id,
              "dm_id" => dm_id,
              "content" => "hi from remote",
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" =>
                canonical_actor("alice", remote_domain,
                  display_name: "Alice Remote",
                  uri: "https://remote.example/users/alice"
                )
            }
          },
          secret: "dm-secret"
        )

      assert {:ok, :applied} = Federation.receive_event(event, remote_domain)

      assert remote_dm_conversation =
               Repo.one(
                 from(c in Conversation,
                   where: c.type == "dm",
                   where: like(c.federated_source, "arblarg:dm:%"),
                   limit: 1
                 )
               )

      assert Messaging.remote_dm_handle(remote_dm_conversation) == "alice@remote.example"

      assert Repo.get_by(ConversationMember,
               conversation_id: remote_dm_conversation.id,
               user_id: recipient.id
             )

      assert inbound_message =
               Repo.get_by(ChatMessage,
                 conversation_id: remote_dm_conversation.id,
                 federated_source: message_federation_id
               )

      assert inbound_message.content == "hi from remote"
      assert inbound_message.origin_domain == remote_domain

      assert get_in(inbound_message.media_metadata, ["remote_sender", "handle"]) ==
               "alice@remote.example"
    end

    test "builds optional E2EE fields and local device discovery into outbound dm.message.create" do
      sender = AccountsFixtures.user_fixture()
      remote_handle = "alice@remote.example"

      {:ok, _device} =
        Messaging.register_chat_encryption_device(sender.id, chat_device_attrs("sender-device"))

      conversation =
        %Conversation{}
        |> Conversation.dm_changeset(%{
          creator_id: sender.id,
          federated_source:
            Elektrine.Messaging.Federation.DirectMessageState.remote_dm_source(remote_handle)
        })
        |> Repo.insert!()

      conversation.id
      |> ConversationMember.add_member_changeset(sender.id)
      |> Repo.insert!()

      encrypted_payload = federated_encrypted_payload("key-test-123456")

      message =
        %ChatMessage{}
        |> ChatMessage.changeset(%{
          conversation_id: conversation.id,
          sender_id: sender.id,
          message_type: "text",
          client_encrypted_payload: encrypted_payload
        })
        |> Repo.insert!()

      assert {:ok, event} =
               Elektrine.Messaging.Federation.Builders.build_dm_message_created_event(
                 message,
                 remote_handle,
                 builder_context()
               )

      assert event["event_type"] == ArblargSDK.dm_message_create_event_type()
      assert get_in(event, ["payload", "message", "content"]) == ""

      assert get_in(event, ["payload", "message", "client_encrypted_payload"]) ==
               encrypted_payload

      assert [device] = get_in(event, ["payload", "dm", "sender", "chat_encryption_devices"])
      assert device["device_id"] == "sender-device"
    end

    test "stores inbound optional E2EE payloads and advertised remote devices" do
      recipient = AccountsFixtures.user_fixture()
      remote_domain = "remote.example"
      local_domain = Federation.local_domain()
      dm_id = "https://remote.example/_arblarg/dms/encrypted-#{recipient.id}"
      stream_id = "dm:#{dm_id}"
      encrypted_payload = federated_encrypted_payload("key-test-123456")

      remote_actor =
        canonical_actor("alice", remote_domain,
          display_name: "Alice Remote",
          uri: "https://remote.example/users/alice"
        )
        |> Map.put("chat_encryption_devices", [chat_device_payload("remote-device")])

      event =
        signed_event(
          ArblargSDK.dm_message_create_event_type(),
          remote_domain,
          stream_id,
          1,
          %{
            "dm" => %{
              "id" => dm_id,
              "sender" => remote_actor,
              "recipient" =>
                canonical_actor(recipient.username, local_domain,
                  uri: "https://#{local_domain}/users/#{recipient.username}"
                )
            },
            "message" => %{
              "id" => "https://remote.example/_arblarg/messages/#{Ecto.UUID.generate()}",
              "dm_id" => dm_id,
              "content" => "",
              "message_type" => "text",
              "client_encrypted_payload" => encrypted_payload,
              "sender" => remote_actor
            }
          },
          secret: "dm-secret"
        )

      assert {:ok, :applied} = Federation.receive_event(event, remote_domain)

      remote_dm_conversation =
        Repo.one!(
          from(c in Conversation,
            where: c.type == "dm",
            where: like(c.federated_source, "arblarg:dm:%"),
            order_by: [desc: c.id],
            limit: 1
          )
        )

      inbound_message =
        Repo.get_by!(ChatMessage,
          conversation_id: remote_dm_conversation.id,
          client_encrypted_payload: encrypted_payload
        )

      assert inbound_message.content == nil
      assert inbound_message.client_encrypted_payload == encrypted_payload

      assert [remote_device] =
               Messaging.list_chat_encryption_devices_for_conversation(remote_dm_conversation.id)

      assert remote_device.device_id == "remote-device"
      assert remote_device.recipient_handle == "alice@remote.example"
    end
  end

  defp chat_device_attrs(device_id) do
    %{
      "device_id" => device_id,
      "public_key" => %{
        "version" => 1,
        "algorithm" => "RSA-OAEP-SHA256",
        "key" => Base.encode64(:crypto.strong_rand_bytes(64))
      },
      "key_algorithm" => "RSA-OAEP-SHA256",
      "label" => "test browser"
    }
  end

  defp chat_device_payload(device_id) do
    chat_device_attrs(device_id)
    |> Map.take(["device_id", "public_key", "key_algorithm", "label"])
  end

  defp federated_encrypted_payload(key_uid) do
    %{
      "version" => 1,
      "content_algorithm" => "AES-256-GCM",
      "key_uid" => key_uid,
      "iv" => Base.encode64(:crypto.strong_rand_bytes(12)),
      "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "federated_key_packages" => [
        %{
          "recipient_handle" => "alice@remote.example",
          "device_id" => "remote-device",
          "wrapped_key" => %{
            "version" => 1,
            "key_algorithm" => "RSA-OAEP-SHA256",
            "encrypted_key" => Base.encode64(:crypto.strong_rand_bytes(48))
          }
        }
      ]
    }
  end

  defp builder_context do
    %{
      local_domain: &Elektrine.Messaging.Federation.Runtime.local_domain/0,
      local_event_signing_material:
        &Elektrine.Messaging.Federation.Runtime.local_event_signing_material/0,
      outgoing_peers: &Federation.outgoing_peers/0,
      maybe_iso8601: fn
        %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
        nil -> nil
        _ -> nil
      end,
      normalize_optional_string: fn
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end

        _ ->
          nil
      end,
      presence_ttl_seconds: fn -> 60 end
    }
  end

  defp signed_event(event_type, remote_domain, stream_id, sequence, payload, opts) do
    key_id = Keyword.get(opts, :key_id, "k1")
    secret = Keyword.get(opts, :secret, "test-shared-secret")

    unsigned = %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "event_id" => Keyword.get(opts, :event_id, "evt-#{Ecto.UUID.generate()}"),
      "event_type" => event_type,
      "origin_domain" => remote_domain,
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => Keyword.get(opts, :sent_at, DateTime.utc_now() |> DateTime.to_iso8601()),
      "idempotency_key" => Keyword.get(opts, :idempotency_key, "idem-#{Ecto.UUID.generate()}"),
      "payload" => payload
    }

    ArblargSDK.sign_event_envelope(unsigned, key_id, secret)
  end

  defp canonical_actor(username, domain, opts) do
    uri =
      Keyword.get(opts, :uri) ||
        "https://#{domain}/users/#{username}"

    {public_key, _private_key} = ArblargSDK.derive_keypair_from_secret("actor:#{uri}")

    %{
      "id" => uri,
      "uri" => uri,
      "username" => username,
      "display_name" => Keyword.get(opts, :display_name, username),
      "domain" => domain,
      "handle" => "#{username}@#{domain}",
      "key_id" => "#{uri}#arblarg-key",
      "public_key" => Base.url_encode64(public_key, padding: false)
    }
  end
end
