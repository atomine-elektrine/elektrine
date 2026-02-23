defmodule Elektrine.Messaging.FederationTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging

  alias Elektrine.Messaging.{
    ChatMessage,
    ChatMessageReaction,
    Conversation,
    ConversationMember,
    Federation,
    FederationExtensionEvent,
    FederationOutboxEvent,
    FederationPresenceState,
    FederationReadReceipt,
    Server
  }

  alias Elektrine.PubSubTopics
  alias Elektrine.Repo

  describe "build_server_snapshot/2" do
    test "builds snapshot with channels and recent messages" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "snapshot-space"})

      {:ok, ops_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "operations"
        })

      {:ok, _message} =
        Messaging.create_chat_text_message(ops_channel.id, owner.id, "hello federation")

      assert {:ok, payload} =
               Federation.build_server_snapshot(server.id, messages_per_channel: 10)

      assert payload["version"] == 1
      assert payload["server"]["name"] == "snapshot-space"
      assert Enum.any?(payload["channels"], &(&1["name"] == "ops"))
      assert Enum.any?(payload["messages"], &(&1["content"] == "hello federation"))
    end
  end

  describe "import_server_snapshot/2" do
    test "imports mirror server, channels, and deduplicates messages by federated_source" do
      payload = %{
        "version" => 1,
        "origin_domain" => "remote.example",
        "server" => %{
          "id" => "https://remote.example/federation/messaging/servers/42",
          "name" => "remote-hub",
          "description" => "Remote server",
          "is_public" => true,
          "member_count" => 12
        },
        "channels" => [
          %{
            "id" => "https://remote.example/federation/messaging/channels/100",
            "name" => "general",
            "description" => "General remote chat",
            "topic" => "hello",
            "position" => 0
          }
        ],
        "messages" => [
          %{
            "id" => "https://remote.example/federation/messaging/messages/5000",
            "channel_id" => "https://remote.example/federation/messaging/channels/100",
            "content" => "remote hello",
            "message_type" => "text",
            "media_urls" => [],
            "media_metadata" => %{},
            "sender" => %{
              "handle" => "alice@remote.example",
              "username" => "alice",
              "domain" => "remote.example"
            }
          }
        ]
      }

      assert {:ok, mirror_server} = Federation.import_server_snapshot(payload, "remote.example")
      assert mirror_server.is_federated_mirror == true
      assert mirror_server.federation_id == payload["server"]["id"]

      mirror_channel =
        Repo.get_by(Conversation,
          type: "channel",
          federated_source: "https://remote.example/federation/messaging/channels/100"
        )

      assert mirror_channel
      assert mirror_channel.server_id == mirror_server.id
      assert mirror_channel.is_federated_mirror == true

      mirror_message =
        Repo.get_by(ChatMessage,
          conversation_id: mirror_channel.id,
          federated_source: "https://remote.example/federation/messaging/messages/5000"
        )

      assert mirror_message
      assert mirror_message.content == "remote hello"
      assert mirror_message.is_federated_mirror == true
      assert mirror_message.origin_domain == "remote.example"

      # Re-import should not duplicate chat message
      assert {:ok, _same_server} = Federation.import_server_snapshot(payload, "remote.example")

      mirror_count =
        from(m in ChatMessage,
          where:
            m.conversation_id == ^mirror_channel.id and
              m.federated_source == "https://remote.example/federation/messaging/messages/5000",
          select: count()
        )
        |> Repo.one()

      assert mirror_count == 1

      # sanity checks for stored mirror server records
      stored_server = Repo.get(Server, mirror_server.id)
      assert stored_server.origin_domain == "remote.example"
    end

    test "rejects conflicting server ownership for identical federation id" do
      base_payload = %{
        "version" => 1,
        "server" => %{
          "id" => "https://shared.example/federation/messaging/servers/42",
          "name" => "shared",
          "description" => "Shared server",
          "is_public" => true,
          "member_count" => 12
        },
        "channels" => [],
        "messages" => []
      }

      payload_one = Map.put(base_payload, "origin_domain", "remote-a.example")
      payload_two = Map.put(base_payload, "origin_domain", "remote-b.example")

      assert {:ok, _mirror_server} =
               Federation.import_server_snapshot(payload_one, "remote-a.example")

      assert {:error, :federation_origin_conflict} =
               Federation.import_server_snapshot(payload_two, "remote-b.example")
    end
  end

  describe "signatures and ordered events" do
    test "verifies peer signatures by key id" do
      peer = %{
        keys: [
          %{id: "k1", secret: "secret-new"},
          %{id: "k0", secret: "secret-old"}
        ]
      }

      domain = "remote.example"
      method = "POST"
      path = "/federation/messaging/events"
      timestamp = Integer.to_string(System.system_time(:second))

      payload = Federation.signature_payload(domain, method, path, "", timestamp)
      old_signature = Federation.sign_payload(payload, "secret-old")

      assert Federation.verify_signature(
               peer,
               domain,
               method,
               path,
               "",
               timestamp,
               "k0",
               old_signature
             )

      refute Federation.verify_signature(
               peer,
               domain,
               method,
               path,
               "",
               timestamp,
               "k1",
               old_signature
             )

      refute Federation.verify_signature(
               peer,
               domain,
               method,
               "/federation/messaging/sync",
               "",
               timestamp,
               "k0",
               old_signature
             )
    end

    test "binds signatures to content digest" do
      peer = %{keys: [%{id: "k0", secret: "secret-old"}]}
      domain = "remote.example"
      method = "POST"
      path = "/federation/messaging/events"
      timestamp = Integer.to_string(System.system_time(:second))
      body = ~s({"event":"x"})
      digest = Federation.body_digest(body)

      signature =
        Federation.signature_payload(domain, method, path, "", timestamp, digest)
        |> Federation.sign_payload("secret-old")

      assert Federation.verify_signature(
               peer,
               domain,
               method,
               path,
               "",
               timestamp,
               digest,
               "k0",
               signature
             )

      refute Federation.verify_signature(
               peer,
               domain,
               method,
               path,
               "",
               timestamp,
               Federation.body_digest(~s({"event":"tampered"})),
               "k0",
               signature
             )
    end

    test "rejects replayed request nonces" do
      domain = "remote.example"
      method = "POST"
      path = "/federation/messaging/events"
      query = ""
      timestamp = Integer.to_string(System.system_time(:second))
      content_digest = Federation.body_digest(~s({"k":"v"}))
      request_id = Ecto.UUID.generate()
      signature = "sig-value"

      assert :ok =
               Federation.claim_request_nonce(
                 domain,
                 "k1",
                 method,
                 path,
                 query,
                 timestamp,
                 content_digest,
                 request_id,
                 signature
               )

      assert {:error, :replayed_request} =
               Federation.claim_request_nonce(
                 domain,
                 "k1",
                 method,
                 path,
                 query,
                 timestamp,
                 content_digest,
                 request_id,
                 signature
               )
    end

    test "applies events in-order and de-duplicates by event id" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/federation/messaging/servers/501"
      stream_id = "server:#{server_id}"

      event1 = %{
        "version" => 1,
        "event_id" => "evt-a-#{Ecto.UUID.generate()}",
        "event_type" => "server.upsert",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 1,
        "data" => %{
          "server" => %{
            "id" => server_id,
            "name" => "remote-seq-1",
            "description" => "first",
            "is_public" => true,
            "member_count" => 1
          },
          "channels" => []
        }
      }

      assert {:ok, :applied} = Federation.receive_event(event1, remote_domain)
      assert {:ok, :duplicate} = Federation.receive_event(event1, remote_domain)

      stale_event =
        event1
        |> Map.put("event_id", "evt-stale-#{Ecto.UUID.generate()}")
        |> Map.put("sequence", 1)

      assert {:ok, :stale} = Federation.receive_event(stale_event, remote_domain)

      gap_event =
        event1
        |> Map.put("event_id", "evt-gap-#{Ecto.UUID.generate()}")
        |> Map.put("sequence", 3)

      assert {:error, :sequence_gap} = Federation.receive_event(gap_event, remote_domain)

      event2 = %{
        "version" => 1,
        "event_id" => "evt-b-#{Ecto.UUID.generate()}",
        "event_type" => "server.upsert",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 2,
        "data" => %{
          "server" => %{
            "id" => server_id,
            "name" => "remote-seq-2",
            "description" => "second",
            "is_public" => true,
            "member_count" => 2
          },
          "channels" => []
        }
      }

      assert {:ok, :applied} = Federation.receive_event(event2, remote_domain)

      mirror_server = Repo.get_by(Server, federation_id: server_id)
      assert mirror_server.name == "remote-seq-2"
      assert mirror_server.member_count == 2
    end

    test "applies message update and delete events" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/federation/messaging/servers/700"
      channel_id = "https://remote.example/federation/messaging/channels/701"
      message_id = "https://remote.example/federation/messaging/messages/702"
      stream_id = "channel:#{channel_id}"

      create_event = %{
        "version" => 1,
        "event_id" => "evt-create-#{Ecto.UUID.generate()}",
        "event_type" => "message.create",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 1,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "message" => %{
            "id" => message_id,
            "channel_id" => channel_id,
            "content" => "first",
            "message_type" => "text",
            "media_urls" => [],
            "media_metadata" => %{},
            "sender" => %{"username" => "alice", "domain" => remote_domain}
          }
        }
      }

      assert {:ok, :applied} = Federation.receive_event(create_event, remote_domain)

      update_event = %{
        "version" => 1,
        "event_id" => "evt-update-#{Ecto.UUID.generate()}",
        "event_type" => "message.update",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 2,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "message" => %{
            "id" => message_id,
            "channel_id" => channel_id,
            "content" => "updated",
            "message_type" => "text",
            "media_urls" => [],
            "media_metadata" => %{},
            "edited_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "sender" => %{"username" => "alice", "domain" => remote_domain}
          }
        }
      }

      assert {:ok, :applied} = Federation.receive_event(update_event, remote_domain)

      mirror_channel = Repo.get_by(Conversation, type: "channel", federated_source: channel_id)

      mirror_message =
        Repo.get_by(ChatMessage, conversation_id: mirror_channel.id, federated_source: message_id)

      assert mirror_message.content == "updated"
      assert not is_nil(mirror_message.edited_at)

      delete_event = %{
        "version" => 1,
        "event_id" => "evt-delete-#{Ecto.UUID.generate()}",
        "event_type" => "message.delete",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 3,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "message_id" => message_id,
          "deleted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      assert {:ok, :applied} = Federation.receive_event(delete_event, remote_domain)

      deleted_message = Repo.get!(ChatMessage, mirror_message.id)
      assert not is_nil(deleted_message.deleted_at)
    end

    test "applies reaction add and remove events" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/federation/messaging/servers/800"
      channel_id = "https://remote.example/federation/messaging/channels/801"
      message_id = "https://remote.example/federation/messaging/messages/802"
      stream_id = "channel:#{channel_id}"
      actor_uri = "https://remote.example/users/alice"

      {:ok, _actor} =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "alice",
          domain: remote_domain,
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert()

      create_event = %{
        "version" => 1,
        "event_id" => "evt-create-rx-#{Ecto.UUID.generate()}",
        "event_type" => "message.create",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 1,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "message" => %{
            "id" => message_id,
            "channel_id" => channel_id,
            "content" => "reaction target",
            "message_type" => "text",
            "media_urls" => [],
            "media_metadata" => %{},
            "sender" => %{"username" => "bob", "domain" => remote_domain}
          }
        }
      }

      assert {:ok, :applied} = Federation.receive_event(create_event, remote_domain)

      reaction_add_event = %{
        "version" => 1,
        "event_id" => "evt-radd-#{Ecto.UUID.generate()}",
        "event_type" => "reaction.add",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 2,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "message_id" => message_id,
          "reaction" => %{
            "emoji" => "👍",
            "actor" => %{"uri" => actor_uri}
          }
        }
      }

      assert {:ok, :applied} = Federation.receive_event(reaction_add_event, remote_domain)

      mirror_channel = Repo.get_by(Conversation, type: "channel", federated_source: channel_id)

      mirror_message =
        Repo.get_by(ChatMessage, conversation_id: mirror_channel.id, federated_source: message_id)

      assert %ChatMessageReaction{} =
               Repo.get_by(ChatMessageReaction,
                 chat_message_id: mirror_message.id,
                 emoji: "👍"
               )

      reaction_remove_event = %{
        "version" => 1,
        "event_id" => "evt-rdel-#{Ecto.UUID.generate()}",
        "event_type" => "reaction.remove",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 3,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "message_id" => message_id,
          "reaction" => %{
            "emoji" => "👍",
            "actor" => %{"uri" => actor_uri}
          }
        }
      }

      assert {:ok, :applied} = Federation.receive_event(reaction_remove_event, remote_domain)

      assert nil ==
               Repo.get_by(ChatMessageReaction,
                 chat_message_id: mirror_message.id,
                 emoji: "👍"
               )
    end

    test "accepts read receipt events for mirrored messages" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/federation/messaging/servers/900"
      channel_id = "https://remote.example/federation/messaging/channels/901"
      message_id = "https://remote.example/federation/messaging/messages/902"
      stream_id = "channel:#{channel_id}"
      actor_uri = "https://remote.example/users/reader"

      {:ok, actor} =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "reader",
          domain: remote_domain,
          inbox_url: "https://remote.example/users/reader/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert()

      create_event = %{
        "version" => 1,
        "event_id" => "evt-create-read-#{Ecto.UUID.generate()}",
        "event_type" => "message.create",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 1,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "message" => %{
            "id" => message_id,
            "channel_id" => channel_id,
            "content" => "read target",
            "message_type" => "text",
            "media_urls" => [],
            "media_metadata" => %{},
            "sender" => %{"username" => "bob", "domain" => remote_domain}
          }
        }
      }

      assert {:ok, :applied} = Federation.receive_event(create_event, remote_domain)

      read_receipt_event = %{
        "version" => 1,
        "event_id" => "evt-read-#{Ecto.UUID.generate()}",
        "event_type" => "read.receipt",
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 2,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "message_id" => message_id,
          "actor" => %{"uri" => actor_uri},
          "read_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      assert {:ok, :applied} = Federation.receive_event(read_receipt_event, remote_domain)

      mirror_channel = Repo.get_by(Conversation, type: "channel", federated_source: channel_id)

      mirror_message =
        Repo.get_by(ChatMessage, conversation_id: mirror_channel.id, federated_source: message_id)

      assert %FederationReadReceipt{} =
               Repo.get_by(FederationReadReceipt,
                 chat_message_id: mirror_message.id,
                 remote_actor_id: actor.id
               )

      read_status = Messaging.get_read_status_for_messages([mirror_message.id], mirror_channel.id)
      readers = Map.get(read_status, mirror_message.id, [])

      assert Enum.any?(readers, fn reader ->
               reader.remote_actor_id == actor.id
             end)
    end

    test "applies extension events and surfaces projections for chat UI" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/federation/messaging/servers/990"
      channel_id = "https://remote.example/federation/messaging/channels/991"
      channel_stream = "channel:#{channel_id}"
      server_stream = "server:#{server_id}"
      actor_uri = "https://remote.example/users/modbot"

      role_upsert_event_type = Elektrine.Messaging.ArblargSDK.canonical_event_type("role.upsert")

      role_assignment_event_type =
        Elektrine.Messaging.ArblargSDK.canonical_event_type("role.assignment.upsert")

      permission_event_type =
        Elektrine.Messaging.ArblargSDK.canonical_event_type("permission.overwrite.upsert")

      thread_upsert_event_type =
        Elektrine.Messaging.ArblargSDK.canonical_event_type("thread.upsert")

      thread_archive_event_type =
        Elektrine.Messaging.ArblargSDK.canonical_event_type("thread.archive")

      moderation_event_type =
        Elektrine.Messaging.ArblargSDK.canonical_event_type("moderation.action.recorded")

      role_upsert_event = %{
        "version" => 1,
        "event_id" => "evt-role-upsert-#{Ecto.UUID.generate()}",
        "event_type" => "role.upsert",
        "origin_domain" => remote_domain,
        "stream_id" => channel_stream,
        "sequence" => 1,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "role" => %{
            "id" => "role-ops",
            "name" => "Ops",
            "position" => 1,
            "permissions" => ["manage_channels", "manage_messages"]
          }
        }
      }

      role_assignment_event = %{
        "version" => 1,
        "event_id" => "evt-role-assignment-#{Ecto.UUID.generate()}",
        "event_type" => "role.assignment.upsert",
        "origin_domain" => remote_domain,
        "stream_id" => channel_stream,
        "sequence" => 2,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "assignment" => %{
            "role_id" => "role-ops",
            "target" => %{"type" => "member", "id" => "member-42"},
            "state" => "assigned"
          }
        }
      }

      permission_overwrite_event = %{
        "version" => 1,
        "event_id" => "evt-perm-overwrite-#{Ecto.UUID.generate()}",
        "event_type" => "permission.overwrite.upsert",
        "origin_domain" => remote_domain,
        "stream_id" => channel_stream,
        "sequence" => 3,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "overwrite" => %{
            "id" => "overwrite-1",
            "target" => %{"type" => "role", "id" => "role-ops"},
            "allow" => ["send_messages"],
            "deny" => ["attach_files"]
          }
        }
      }

      thread_upsert_event = %{
        "version" => 1,
        "event_id" => "evt-thread-upsert-#{Ecto.UUID.generate()}",
        "event_type" => "thread.upsert",
        "origin_domain" => remote_domain,
        "stream_id" => channel_stream,
        "sequence" => 4,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "thread" => %{
            "id" => "thread-9000",
            "channel_id" => channel_id,
            "name" => "Incident 9000",
            "state" => "active",
            "owner" => %{"id" => "owner-1", "type" => "member"},
            "message_count" => 12,
            "member_count" => 4
          }
        }
      }

      thread_archive_event = %{
        "version" => 1,
        "event_id" => "evt-thread-archive-#{Ecto.UUID.generate()}",
        "event_type" => "thread.archive",
        "origin_domain" => remote_domain,
        "stream_id" => channel_stream,
        "sequence" => 5,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "thread_id" => "thread-9000",
          "archived_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "actor" => %{"uri" => actor_uri},
          "reason" => "resolved"
        }
      }

      moderation_action_event = %{
        "version" => 1,
        "event_id" => "evt-moderation-#{Ecto.UUID.generate()}",
        "event_type" => "moderation.action.recorded",
        "origin_domain" => remote_domain,
        "stream_id" => channel_stream,
        "sequence" => 6,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
          "action" => %{
            "id" => "mod-action-1",
            "kind" => "timeout",
            "target" => %{"type" => "member", "id" => "member-42"},
            "actor" => %{"uri" => actor_uri},
            "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "duration_seconds" => 600,
            "reason" => "spam"
          }
        }
      }

      presence_update_event = %{
        "version" => 1,
        "event_id" => "evt-presence-#{Ecto.UUID.generate()}",
        "event_type" => "presence.update",
        "origin_domain" => remote_domain,
        "stream_id" => server_stream,
        "sequence" => 1,
        "data" => %{
          "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
          "presence" => %{
            "actor" => %{
              "uri" => actor_uri,
              "username" => "modbot",
              "domain" => remote_domain,
              "display_name" => "Mod Bot"
            },
            "status" => "online",
            "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "activities" => [%{"name" => "Moderating"}]
          }
        }
      }

      Phoenix.PubSub.subscribe(Elektrine.PubSub, PubSubTopics.users_presence())

      assert {:ok, :applied} = Federation.receive_event(role_upsert_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(role_assignment_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(permission_overwrite_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(thread_upsert_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(thread_archive_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(moderation_action_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(presence_update_event, remote_domain)
      assert_receive {:federation_presence_update, presence_broadcast}, 1_000
      assert is_integer(presence_broadcast.server_id)
      assert presence_broadcast.status == "online"
      assert presence_broadcast.handle == "@modbot@remote.example"

      mirror_server = Repo.get_by(Server, federation_id: server_id)
      mirror_channel = Repo.get_by(Conversation, type: "channel", federated_source: channel_id)
      assert mirror_server
      assert mirror_channel

      assert Repo.get_by(FederationExtensionEvent,
               event_type: role_upsert_event_type,
               origin_domain: remote_domain,
               event_key: "role:role-ops:channel:#{mirror_channel.id}"
             )

      assert Repo.get_by(FederationExtensionEvent,
               event_type: role_assignment_event_type,
               origin_domain: remote_domain,
               event_key: "role_assignment:role-ops:member:member-42:channel:#{mirror_channel.id}"
             )

      assert Repo.get_by(FederationExtensionEvent,
               event_type: permission_event_type,
               origin_domain: remote_domain,
               event_key: "overwrite:overwrite-1:channel:#{mirror_channel.id}"
             )

      assert Repo.get_by(FederationExtensionEvent,
               event_type: thread_upsert_event_type,
               origin_domain: remote_domain,
               event_key: "thread:thread-9000:channel:#{mirror_channel.id}"
             )

      assert Repo.get_by(FederationExtensionEvent,
               event_type: thread_archive_event_type,
               origin_domain: remote_domain,
               event_key: "thread:thread-9000:channel:#{mirror_channel.id}"
             )

      assert Repo.get_by(FederationExtensionEvent,
               event_type: moderation_event_type,
               origin_domain: remote_domain,
               event_key: "moderation:mod-action-1:channel:#{mirror_channel.id}"
             )

      assert Repo.get_by(FederationPresenceState,
               server_id: mirror_server.id,
               status: "online"
             )

      assert Enum.any?(Federation.list_server_presence_states(mirror_server.id), fn state ->
               state.status == "online"
             end)

      extension_messages =
        from(m in ChatMessage,
          where:
            m.conversation_id == ^mirror_channel.id and
              m.message_type == "system" and
              like(m.federated_source, "arbp:ext:%")
        )
        |> Repo.all()

      assert Enum.any?(extension_messages, &String.contains?(&1.content || "", "Role updated"))

      assert Enum.any?(
               extension_messages,
               &String.contains?(&1.content || "", "Permissions updated")
             )

      assert Enum.any?(extension_messages, &String.contains?(&1.content || "", "Thread archived"))

      assert Enum.any?(
               extension_messages,
               &String.contains?(&1.content || "", "Moderation action")
             )
    end
  end

  describe "cross-instance DMs (ARBP)" do
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
              allow_outgoing: true
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
      sender = AccountsFixtures.user_fixture()
      dm_event_type = Elektrine.Messaging.ArblargSDK.dm_message_create_event_type()

      assert {:ok, dm_conversation} =
               Messaging.create_remote_dm_conversation(sender.id, "alice@remote.example")

      assert {:ok, _message} =
               Messaging.create_text_message(dm_conversation.id, sender.id, "hello remote dm")

      assert outbox_event =
               Repo.one(
                 from(o in FederationOutboxEvent,
                   where: o.event_type == ^dm_event_type,
                   order_by: [desc: o.inserted_at],
                   limit: 1
                 )
               )

      assert outbox_event.event_type == dm_event_type
      assert outbox_event.target_domains == ["remote.example"]

      assert get_in(outbox_event.payload, ["payload", "dm", "recipient", "handle"]) ==
               "alice@remote.example"
    end

    test "applies inbound dm.message.create and creates a federated DM conversation" do
      recipient = AccountsFixtures.user_fixture()
      remote_domain = "remote.example"
      stream_id = "dm:https://remote.example/federation/messaging/dms/alice-#{recipient.id}"
      local_domain = Federation.local_domain()

      message_federation_id =
        "https://remote.example/federation/messaging/messages/#{Ecto.UUID.generate()}"

      event = %{
        "version" => 1,
        "event_id" => "evt-dm-#{Ecto.UUID.generate()}",
        "event_type" => Elektrine.Messaging.ArblargSDK.dm_message_create_event_type(),
        "origin_domain" => remote_domain,
        "stream_id" => stream_id,
        "sequence" => 1,
        "data" => %{
          "dm" => %{
            "id" => "https://remote.example/federation/messaging/dms/alice-#{recipient.id}",
            "sender" => %{
              "username" => "alice",
              "display_name" => "Alice Remote",
              "domain" => remote_domain,
              "handle" => "alice@remote.example"
            },
            "recipient" => %{
              "username" => recipient.username,
              "domain" => local_domain,
              "handle" => "#{recipient.username}@#{local_domain}"
            }
          },
          "message" => %{
            "id" => message_federation_id,
            "dm_id" => "https://remote.example/federation/messaging/dms/alice-#{recipient.id}",
            "content" => "hi from remote",
            "message_type" => "text",
            "media_urls" => [],
            "media_metadata" => %{},
            "sender" => %{
              "username" => "alice",
              "display_name" => "Alice Remote",
              "domain" => remote_domain,
              "handle" => "alice@remote.example"
            }
          }
        }
      }

      assert {:ok, :applied} = Federation.receive_event(event, remote_domain)

      assert remote_dm_conversation =
               Repo.get_by(Conversation,
                 type: "dm",
                 federated_source: "arbp:dm:alice@remote.example"
               )

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
  end

  describe "runtime peer policies" do
    setup do
      original_config = Application.get_env(:elektrine, :messaging_federation, [])

      peer = %{
        domain: "remote.example",
        base_url: "https://remote.example",
        shared_secret: "test-secret",
        allow_incoming: true,
        allow_outgoing: true
      }

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.put(original_config, :peers, [peer])
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, original_config)
      end)

      :ok
    end

    test "block policy disables incoming and outgoing federation" do
      assert Federation.incoming_peer("remote.example")
      assert length(Federation.outgoing_peers()) == 1

      assert {:ok, _policy} = Federation.block_peer_domain("remote.example", "manual block")

      assert is_nil(Federation.incoming_peer("remote.example"))
      assert Federation.outgoing_peers() == []
    end

    test "directional runtime overrides affect only selected direction" do
      assert {:ok, _policy} =
               Federation.upsert_peer_policy("remote.example", %{
                 blocked: false,
                 allow_incoming: false
               })

      assert is_nil(Federation.incoming_peer("remote.example"))
      assert length(Federation.outgoing_peers()) == 1

      assert {:ok, _policy} =
               Federation.upsert_peer_policy("remote.example", %{
                 blocked: false,
                 allow_incoming: nil,
                 allow_outgoing: false
               })

      assert Federation.incoming_peer("remote.example")
      assert Federation.outgoing_peers() == []
    end

    test "peer controls include runtime-only block entries" do
      assert {:ok, _policy} = Federation.block_peer_domain("manual.example", "proactive block")

      controls = Federation.list_peer_controls()

      assert Enum.any?(controls, fn control ->
               control.domain == "manual.example" and control.configured == false and
                 control.blocked == true
             end)
    end
  end

  describe "relay transport metadata" do
    test "includes relay metadata in discovery document" do
      previous = Application.get_env(:elektrine, :messaging_federation)

      Application.put_env(
        :elektrine,
        :messaging_federation,
        enabled: true,
        identity_key_id: "k-relay",
        official_relay_operator: "Relay Collective",
        official_relays: [
          %{
            "name" => "Relay US-East",
            "url" => "https://relay-us-east.example.com"
          },
          "https://relay-eu.example.com"
        ],
        peers: []
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      discovery = Federation.local_discovery_document()

      assert discovery["features"]["relay_transport"] == true
      assert discovery["relay_transport"]["mode"] == "optional"
      assert discovery["relay_transport"]["community_hostable"] == true
      assert discovery["relay_transport"]["official_operator"] == "Relay Collective"

      relay_urls =
        discovery["relay_transport"]["official_relays"]
        |> Enum.map(& &1["url"])

      assert "https://relay-us-east.example.com" in relay_urls
      assert "https://relay-eu.example.com" in relay_urls
    end

    test "normalizes peer relay endpoint overrides" do
      previous = Application.get_env(:elektrine, :messaging_federation)

      Application.put_env(
        :elektrine,
        :messaging_federation,
        enabled: true,
        peers: [
          %{
            "domain" => "remote.example",
            "base_url" => "https://remote.example/",
            "shared_secret" => "relay-secret",
            "event_endpoint" => "https://relay.example.net/fwd/events",
            "sync_endpoint" => "https://relay.example.net/fwd/sync",
            "snapshot_endpoint_template" => "https://relay.example.net/fwd/snapshots/{server_id}"
          }
        ]
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      [peer] = Federation.outgoing_peers()

      assert peer.base_url == "https://remote.example"
      assert peer.event_endpoint == "https://relay.example.net/fwd/events"
      assert peer.sync_endpoint == "https://relay.example.net/fwd/sync"

      assert peer.snapshot_endpoint_template ==
               "https://relay.example.net/fwd/snapshots/{server_id}"
    end
  end
end
