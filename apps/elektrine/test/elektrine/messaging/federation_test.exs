defmodule Elektrine.Messaging.FederationTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging

  alias Elektrine.Messaging.{
    ArblargSDK,
    ChatMessage,
    ChatMessageReaction,
    Conversation,
    ConversationMember,
    Federation,
    FederationDiscoveredPeer,
    FederationExtensionEvent,
    FederationMembershipState,
    FederationOutboxEvent,
    FederationPresenceState,
    FederationReadCursor,
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

    test "includes invite governance projections in snapshot payloads" do
      owner = AccountsFixtures.user_fixture()
      invitee = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "governance-space"})

      {:ok, ops_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "operations"
        })

      assert :ok =
               Federation.publish_invite_state(
                 ops_channel.id,
                 invitee.id,
                 owner.id,
                 "pending",
                 "member",
                 %{"source" => "snapshot-test"}
               )

      assert {:ok, payload} =
               Federation.build_server_snapshot(server.id, messages_per_channel: 10)

      invites = get_in(payload, ["governance", "invites"]) || []

      assert Enum.any?(invites, fn invite_payload ->
               get_in(invite_payload, ["invite", "target", "handle"]) ==
                 "#{invitee.username}@#{Federation.local_domain()}" and
                 get_in(invite_payload, ["invite", "state"]) == "pending"
             end)
    end
  end

  describe "import_server_snapshot/2" do
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
              shared_secret: "remote-example-secret",
              active_outbound_key_id: "k1",
              keys: [
                %{id: "k1", secret: "remote-example-secret", active_outbound: true}
              ],
              allow_incoming: true,
              allow_outgoing: false
            },
            %{
              domain: "remote-a.example",
              base_url: "https://remote-a.example",
              shared_secret: "remote-a-secret",
              active_outbound_key_id: "k1",
              keys: [
                %{id: "k1", secret: "remote-a-secret", active_outbound: true}
              ],
              allow_incoming: true,
              allow_outgoing: false
            },
            %{
              domain: "remote-b.example",
              base_url: "https://remote-b.example",
              shared_secret: "remote-b-secret",
              active_outbound_key_id: "k1",
              keys: [
                %{id: "k1", secret: "remote-b-secret", active_outbound: true}
              ],
              allow_incoming: true,
              allow_outgoing: false
            }
          ]
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      :ok
    end

    test "imports mirror server, channels, and deduplicates messages by federated_source" do
      payload =
        %{
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
              "sender" => canonical_actor("alice", "remote.example")
            }
          ]
        }
        |> sign_snapshot("k1", "remote-example-secret")

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

    test "rejects conflicting server ownership for an already-mirrored federation id" do
      payload =
        %{
          "version" => 1,
          "origin_domain" => "remote-a.example",
          "server" => %{
            "id" => "https://remote-a.example/federation/messaging/servers/42",
            "name" => "remote-a",
            "description" => "Remote A server",
            "is_public" => true,
            "member_count" => 12
          },
          "channels" => [],
          "messages" => []
        }
        |> sign_snapshot("k1", "remote-a-secret")

      {:ok, _existing_server} =
        %Server{}
        |> Server.changeset(%{
          name: "conflicting-mirror",
          federation_id: "https://remote-a.example/federation/messaging/servers/42",
          origin_domain: "different-origin.example",
          is_federated_mirror: true
        })
        |> Repo.insert()

      assert {:error, :federation_origin_conflict} =
               Federation.import_server_snapshot(payload, "remote-a.example")
    end
  end

  describe "signatures and ordered events" do
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
              shared_secret: "test-shared-secret",
              active_outbound_key_id: "k1",
              keys: [
                %{id: "k1", secret: "test-shared-secret", active_outbound: true}
              ],
              allow_incoming: true,
              allow_outgoing: false
            },
            %{
              domain: "remote-b.example",
              base_url: "https://remote-b.example",
              shared_secret: "test-shared-secret-b",
              active_outbound_key_id: "k1",
              keys: [
                %{id: "k1", secret: "test-shared-secret-b", active_outbound: true}
              ],
              allow_incoming: true,
              allow_outgoing: false
            }
          ]
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      :ok
    end

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

      event1 =
        signed_event(
          "server.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{
              "id" => server_id,
              "name" => "remote-seq-1",
              "description" => "first",
              "is_public" => true,
              "member_count" => 1
            },
            "channels" => []
          }
        )

      assert {:ok, :applied} = Federation.receive_event(event1, remote_domain)
      assert {:ok, :duplicate} = Federation.receive_event(event1, remote_domain)

      stale_event =
        signed_event(
          "server.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{
              "id" => server_id,
              "name" => "remote-seq-1",
              "description" => "first",
              "is_public" => true,
              "member_count" => 1
            },
            "channels" => []
          }
        )

      assert {:ok, :stale} = Federation.receive_event(stale_event, remote_domain)

      gap_event =
        signed_event(
          "server.upsert",
          remote_domain,
          stream_id,
          3,
          %{
            "server" => %{
              "id" => server_id,
              "name" => "remote-seq-3",
              "description" => "third",
              "is_public" => true,
              "member_count" => 3
            },
            "channels" => []
          }
        )

      assert {:error, :sequence_gap} = Federation.receive_event(gap_event, remote_domain)

      event2 =
        signed_event(
          "server.upsert",
          remote_domain,
          stream_id,
          2,
          %{
            "server" => %{
              "id" => server_id,
              "name" => "remote-seq-2",
              "description" => "second",
              "is_public" => true,
              "member_count" => 2
            },
            "channels" => []
          }
        )

      assert {:ok, :applied} = Federation.receive_event(event2, remote_domain)

      mirror_server = Repo.get_by(Server, federation_id: server_id)
      assert mirror_server.name == "remote-seq-2"
      assert mirror_server.member_count == 2
    end

    test "treats matching event ids from different origins as distinct events" do
      shared_event_id = "evt-cross-origin-shared"

      event_a =
        signed_event(
          "server.upsert",
          "remote.example",
          "server:https://remote.example/federation/messaging/servers/901",
          1,
          %{
            "server" => %{
              "id" => "https://remote.example/federation/messaging/servers/901",
              "name" => "remote-a",
              "description" => "first origin",
              "is_public" => true,
              "member_count" => 1
            },
            "channels" => []
          },
          event_id: shared_event_id
        )

      event_b =
        signed_event(
          "server.upsert",
          "remote-b.example",
          "server:https://remote-b.example/federation/messaging/servers/902",
          1,
          %{
            "server" => %{
              "id" => "https://remote-b.example/federation/messaging/servers/902",
              "name" => "remote-b",
              "description" => "second origin",
              "is_public" => true,
              "member_count" => 2
            },
            "channels" => []
          },
          event_id: shared_event_id,
          secret: "test-shared-secret-b"
        )

      assert {:ok, :applied} = Federation.receive_event(event_a, "remote.example")
      assert {:ok, :applied} = Federation.receive_event(event_b, "remote-b.example")

      assert 2 =
               Repo.aggregate(
                 from(e in FederationEvent, where: e.event_id == ^shared_event_id),
                 :count
               )
    end

    test "applies message update and delete events" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/federation/messaging/servers/700"
      channel_id = "https://remote.example/federation/messaging/channels/701"
      message_id = "https://remote.example/federation/messaging/messages/702"
      stream_id = "channel:#{channel_id}"

      create_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "message" => %{
              "id" => message_id,
              "channel_id" => channel_id,
              "content" => "first",
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" => canonical_actor("alice", remote_domain)
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(create_event, remote_domain)

      update_event =
        signed_event(
          "message.update",
          remote_domain,
          stream_id,
          2,
          %{
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
              "sender" => canonical_actor("alice", remote_domain)
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(update_event, remote_domain)

      mirror_channel = Repo.get_by(Conversation, type: "channel", federated_source: channel_id)

      mirror_message =
        Repo.get_by(ChatMessage, conversation_id: mirror_channel.id, federated_source: message_id)

      assert mirror_message.content == "updated"
      assert not is_nil(mirror_message.edited_at)

      delete_event =
        signed_event(
          "message.delete",
          remote_domain,
          stream_id,
          3,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "message_id" => message_id,
            "deleted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        )

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

      create_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "message" => %{
              "id" => message_id,
              "channel_id" => channel_id,
              "content" => "reaction target",
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" => canonical_actor("bob", remote_domain)
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(create_event, remote_domain)

      reaction_add_event =
        signed_event(
          "reaction.add",
          remote_domain,
          stream_id,
          2,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "message_id" => message_id,
            "reaction" => %{
              "emoji" => "👍",
              "actor" => canonical_actor("alice", remote_domain, uri: actor_uri)
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(reaction_add_event, remote_domain)

      mirror_channel = Repo.get_by(Conversation, type: "channel", federated_source: channel_id)

      mirror_message =
        Repo.get_by(ChatMessage, conversation_id: mirror_channel.id, federated_source: message_id)

      assert %ChatMessageReaction{} =
               Repo.get_by(ChatMessageReaction,
                 chat_message_id: mirror_message.id,
                 emoji: "👍"
               )

      reaction_remove_event =
        signed_event(
          "reaction.remove",
          remote_domain,
          stream_id,
          3,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "message_id" => message_id,
            "reaction" => %{
              "emoji" => "👍",
              "actor" => canonical_actor("alice", remote_domain, uri: actor_uri)
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(reaction_remove_event, remote_domain)

      assert nil ==
               Repo.get_by(ChatMessageReaction,
                 chat_message_id: mirror_message.id,
                 emoji: "👍"
               )
    end

    test "rejects remote actor payloads that try to reuse a handle with a new uri" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/federation/messaging/servers/810"
      channel_id = "https://remote.example/federation/messaging/channels/811"
      message_id = "https://remote.example/federation/messaging/messages/812"
      stream_id = "channel:#{channel_id}"
      existing_uri = "https://remote.example/users/alice"
      conflicting_uri = "https://remote.example/actors/alice-renamed"

      {:ok, existing_actor} =
        %Actor{}
        |> Actor.changeset(%{
          uri: existing_uri,
          username: "alice",
          domain: remote_domain,
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert()

      create_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "message" => %{
              "id" => message_id,
              "channel_id" => channel_id,
              "content" => "identity conflict",
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" => canonical_actor("bob", remote_domain)
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(create_event, remote_domain)

      conflict_event =
        signed_event(
          "reaction.add",
          remote_domain,
          stream_id,
          2,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "message_id" => message_id,
            "reaction" => %{
              "emoji" => "🔥",
              "actor" => canonical_actor("alice", remote_domain, uri: conflicting_uri)
            }
          }
        )

      assert {:error, :invalid_event_payload} =
               Federation.receive_event(conflict_event, remote_domain)

      assert Repo.get!(Actor, existing_actor.id).uri == existing_uri

      actor_count =
        from(a in Actor,
          where: a.username == "alice" and a.domain == ^remote_domain,
          select: count()
        )
        |> Repo.one()

      assert actor_count == 1
      refute Repo.get_by(Actor, uri: conflicting_uri)
    end

    test "accepts read cursor events for mirrored messages" do
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

      create_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "message" => %{
              "id" => message_id,
              "channel_id" => channel_id,
              "content" => "read target",
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" => canonical_actor("bob", remote_domain)
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(create_event, remote_domain)

      read_cursor_event =
        signed_event(
          "read.cursor",
          remote_domain,
          stream_id,
          2,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "read_through_message_id" => message_id,
            "actor" => canonical_actor("reader", remote_domain, uri: actor_uri),
            "read_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        )

      assert {:ok, :applied} = Federation.receive_event(read_cursor_event, remote_domain)

      mirror_channel = Repo.get_by(Conversation, type: "channel", federated_source: channel_id)

      mirror_message =
        Repo.get_by(ChatMessage, conversation_id: mirror_channel.id, federated_source: message_id)

      assert %FederationReadCursor{} =
               Repo.get_by(FederationReadCursor,
                 conversation_id: mirror_channel.id,
                 remote_actor_id: actor.id
               )

      read_status = Messaging.get_read_status_for_messages([mirror_message.id], mirror_channel.id)
      readers = Map.get(read_status, mirror_message.id, [])

      assert Enum.any?(readers, fn reader ->
               reader.remote_actor_id == actor.id
             end)
    end

    test "applies invite and ban governance events into membership state projections" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/federation/messaging/servers/910"
      channel_id = "https://remote.example/federation/messaging/channels/911"
      stream_id = "channel:#{channel_id}"

      invite_event =
        signed_event(
          "invite.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "invite" => %{
              "actor" => canonical_actor("mod", remote_domain),
              "target" => canonical_actor("alice", remote_domain),
              "role" => "member",
              "state" => "pending",
              "invited_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{"source" => "test"}
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(invite_event, remote_domain)

      mirror_channel = Repo.get_by(Conversation, type: "channel", federated_source: channel_id)
      target_actor = Repo.get_by(Actor, username: "alice", domain: remote_domain)

      assert %FederationMembershipState{} =
               membership_state =
               Repo.get_by(FederationMembershipState,
                 conversation_id: mirror_channel.id,
                 remote_actor_id: target_actor.id
               )

      assert membership_state.state == "invited"
      assert get_in(membership_state.metadata, ["governance_event"]) == "invite.upsert"

      ban_event =
        signed_event(
          "ban.upsert",
          remote_domain,
          stream_id,
          2,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "ban" => %{
              "actor" => canonical_actor("mod", remote_domain),
              "target" => canonical_actor("alice", remote_domain),
              "state" => "active",
              "reason" => "spam",
              "banned_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{"source" => "test"}
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(ban_event, remote_domain)

      assert %FederationMembershipState{} =
               membership_state =
               Repo.get_by(FederationMembershipState,
                 conversation_id: mirror_channel.id,
                 remote_actor_id: target_actor.id
               )

      assert membership_state.state == "banned"
      assert get_in(membership_state.metadata, ["ban_state"]) == "active"
      assert get_in(membership_state.metadata, ["reason"]) == "spam"
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

      role_upsert_event =
        signed_event(
          "role.upsert",
          remote_domain,
          channel_stream,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "role" => %{
              "id" => "role-ops",
              "name" => "Ops",
              "position" => 1,
              "permissions" => ["manage_channels", "manage_messages"]
            }
          }
        )

      role_assignment_event =
        signed_event(
          "role.assignment.upsert",
          remote_domain,
          channel_stream,
          2,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "assignment" => %{
              "role_id" => "role-ops",
              "target" => %{"type" => "member", "id" => "member-42"},
              "state" => "assigned"
            }
          }
        )

      permission_overwrite_event =
        signed_event(
          "permission.overwrite.upsert",
          remote_domain,
          channel_stream,
          3,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "overwrite" => %{
              "id" => "overwrite-1",
              "target" => %{"type" => "role", "id" => "role-ops"},
              "allow" => ["send_messages"],
              "deny" => ["attach_files"]
            }
          }
        )

      thread_upsert_event =
        signed_event(
          "thread.upsert",
          remote_domain,
          channel_stream,
          4,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "thread" => %{
              "id" => "thread-9000",
              "channel_id" => channel_id,
              "name" => "Incident 9000",
              "state" => "active",
              "owner" => canonical_actor("modbot", remote_domain, uri: actor_uri),
              "message_count" => 12,
              "member_count" => 4
            }
          }
        )

      thread_archive_event =
        signed_event(
          "thread.archive",
          remote_domain,
          channel_stream,
          5,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "thread_id" => "thread-9000",
            "archived_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "actor" => canonical_actor("modbot", remote_domain, uri: actor_uri),
            "reason" => "resolved"
          }
        )

      moderation_action_event =
        signed_event(
          "moderation.action.recorded",
          remote_domain,
          channel_stream,
          6,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "action" => %{
              "id" => "mod-action-1",
              "kind" => "timeout",
              "target" => %{"type" => "member", "id" => "member-42"},
              "actor" => canonical_actor("modbot", remote_domain, uri: actor_uri),
              "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "duration_seconds" => 600,
              "reason" => "spam"
            }
          }
        )

      presence_update_event =
        signed_event(
          "presence.update",
          remote_domain,
          server_stream,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "presence" => %{
              "actor" =>
                canonical_actor("modbot", remote_domain,
                  uri: actor_uri,
                  display_name: "Mod Bot"
                ),
              "status" => "online",
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "activities" => [%{"name" => "Moderating"}]
            }
          }
        )

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
              like(m.federated_source, "arblarg:ext:%")
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

      event =
        signed_event(
          Elektrine.Messaging.ArblargSDK.dm_message_create_event_type(),
          remote_domain,
          stream_id,
          1,
          %{
            "dm" => %{
              "id" => "https://remote.example/federation/messaging/dms/alice-#{recipient.id}",
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
              "dm_id" => "https://remote.example/federation/messaging/dms/alice-#{recipient.id}",
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
               Repo.get_by(Conversation,
                 type: "dm",
                 federated_source: "arblarg:dm:alice@remote.example"
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

  describe "dynamic peer discovery" do
    test "discovers and caches unknown peers from discovery metadata" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [
                authenticated_dns_identity_proof(
                  dynamic_discovery_document("open.example", "open-example-secret")
                )
              ]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, dynamic_discovery_document("open.example", "open-example-secret")}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:ok, peer} = Federation.discover_peer("open.example")
      assert peer.domain == "open.example"
      assert peer.allow_incoming == true
      assert peer.allow_outgoing == true

      assert %FederationDiscoveredPeer{} =
               Repo.get_by(FederationDiscoveredPeer, domain: "open.example")

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          discovery_fetcher: fn _domain, _urls -> {:error, :should_not_refetch} end
        )
      )

      assert %{} = Federation.outgoing_peer("open.example")
      assert %{} = Federation.incoming_peer("open.example")
    end

    test "rejects discovery documents without a claimed domain" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      discovery_document =
        dynamic_discovery_document("open.example", "open-example-secret", claimed_domain: nil)

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [authenticated_dns_identity_proof(discovery_document)]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, discovery_document}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:error, :invalid_discovery_domain} = Federation.discover_peer("open.example")
    end

    test "rejects discovery documents with unsupported default protocol versions" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      discovery_document =
        dynamic_discovery_document("open.example", "open-example-secret",
          default_protocol_version: "9.9"
        )

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [authenticated_dns_identity_proof(discovery_document)]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, discovery_document}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:error, :unsupported_version} = Federation.discover_peer("open.example")
    end

    test "rejects plaintext websocket session endpoints in normal operation" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      discovery_document =
        dynamic_discovery_document("open.example", "open-example-secret",
          session_websocket: "ws://open.example/federation/messaging/session"
        )

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [authenticated_dns_identity_proof(discovery_document)]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, discovery_document}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:error, :invalid_discovery_endpoints} = Federation.discover_peer("open.example")
    end

    test "peer controls surface discovered peer metadata" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [
                authenticated_dns_identity_proof(
                  dynamic_discovery_document("open.example", "open-example-secret")
                )
              ]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, dynamic_discovery_document("open.example", "open-example-secret")}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:ok, _peer} = Federation.discover_peer("open.example")

      assert control =
               Enum.find(Federation.list_peer_controls(), fn control ->
                 control.domain == "open.example"
               end)

      assert control.discovered == true
      assert control.configured == false
      assert control.trust_state == "trusted"
      assert control.protocol_version == "1.0"
      assert control.effective_allow_incoming == true
      assert control.effective_allow_outgoing == true
      assert is_map(control.features)
      assert control.last_discovered_at
    end

    test "replaced discovery identities are quarantined until operator override" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      discovery_versions = :ets.new(:arblarg_discovery_versions, [:set, :public])
      :ets.insert(discovery_versions, {:secret, "first-secret"})

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.swap.example", "swap.example" ->
              [{:secret, secret}] = :ets.lookup(discovery_versions, :secret)

              [
                authenticated_dns_identity_proof(
                  dynamic_discovery_document("swap.example", secret)
                )
              ]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "swap.example", _urls ->
              [{:secret, secret}] = :ets.lookup(discovery_versions, :secret)
              {:ok, dynamic_discovery_document("swap.example", secret)}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        if :ets.info(discovery_versions) != :undefined do
          :ets.delete(discovery_versions)
        end

        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:ok, peer} = Federation.discover_peer("swap.example")
      assert peer.trust_state == "trusted"
      assert %{} = Federation.outgoing_peer("swap.example")

      :ets.insert(discovery_versions, {:secret, "second-secret"})

      assert {:ok, peer} = Federation.refresh_peer_discovery("swap.example")
      assert peer.trust_state == "replaced"
      assert peer.allow_incoming == false
      assert peer.allow_outgoing == false
      assert is_nil(Federation.incoming_peer("swap.example"))
      assert is_nil(Federation.outgoing_peer("swap.example"))

      assert control =
               Enum.find(Federation.list_peer_controls(), fn control ->
                 control.domain == "swap.example"
               end)

      assert control.requires_operator_action == true
      assert control.blocked == true
      assert control.trust_state == "replaced"

      assert {:ok, _policy} =
               Federation.upsert_peer_policy("swap.example", %{
                 blocked: false,
                 allow_incoming: true,
                 allow_outgoing: true
               })

      assert %{} = Federation.incoming_peer("swap.example")
      assert %{} = Federation.outgoing_peer("swap.example")
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

  defp dynamic_discovery_document(domain, secret, opts \\ []) do
    {public_key, _private_key} = ArblargSDK.derive_keypair_from_secret(secret)
    base_url = "https://#{domain}"
    claimed_domain = Keyword.get(opts, :claimed_domain, domain)

    default_protocol_version =
      Keyword.get(opts, :default_protocol_version, ArblargSDK.protocol_version())

    session_websocket =
      Keyword.get(opts, :session_websocket, "wss://#{domain}/federation/messaging/session")

    unsigned =
      %{
        "protocol" => ArblargSDK.protocol_name(),
        "protocol_id" => ArblargSDK.protocol_id(),
        "protocol_labels" => [ArblargSDK.protocol_label()],
        "default_protocol_label" => ArblargSDK.protocol_label(),
        "default_protocol_version" => default_protocol_version,
        "version" => 1,
        "identity" => %{
          "algorithm" => "ed25519",
          "current_key_id" => "k1",
          "keys" => [
            %{
              "id" => "k1",
              "algorithm" => "ed25519",
              "public_key" => Base.url_encode64(public_key, padding: false)
            }
          ]
        },
        "endpoints" => %{
          "well_known" => "#{base_url}/.well-known/arblarg",
          "events" => "#{base_url}/federation/messaging/events",
          "events_batch" => "#{base_url}/federation/messaging/events/batch",
          "ephemeral" => "#{base_url}/federation/messaging/ephemeral",
          "sync" => "#{base_url}/federation/messaging/sync",
          "stream_events" => "#{base_url}/federation/messaging/streams/events",
          "session_websocket" => session_websocket,
          "snapshot_template" => "#{base_url}/federation/messaging/servers/{server_id}/snapshot",
          "public_servers" => "#{base_url}/federation/messaging/servers/public",
          "profiles" => "#{base_url}/federation/messaging/arblarg/profiles",
          "schema_template" => "#{base_url}/federation/messaging/arblarg/{version}/schemas/{name}"
        }
      }
      |> maybe_put_field("domain", claimed_domain)

    Map.put(unsigned, "signature", %{
      "algorithm" => "ed25519",
      "key_id" => "k1",
      "value" =>
        unsigned
        |> ArblargSDK.canonical_json_payload()
        |> ArblargSDK.sign_payload(secret)
    })
  end

  defp maybe_put_field(map, _key, nil), do: map

  defp maybe_put_field(map, key, value) when is_map(map) and is_binary(key) do
    Map.put(map, key, value)
  end

  defp discovery_fingerprint(%{
         "identity" => %{"current_key_id" => current_key_id, "keys" => keys}
       })
       when is_list(keys) do
    normalized =
      keys
      |> Enum.map(fn key ->
        %{
          "id" => key["id"],
          "public_key" => key["public_key"]
        }
      end)
      |> Enum.sort_by(&{&1["id"] || "", &1["public_key"] || ""})

    :crypto.hash(
      :sha256,
      Jason.encode!(%{"current_key_id" => current_key_id, "keys" => normalized})
    )
    |> Base.url_encode64(padding: false)
  end

  defp authenticated_dns_identity_proof(discovery_document) do
    %{
      text: "fingerprint=#{discovery_fingerprint(discovery_document)}",
      authenticated: true
    }
  end

  defp signed_event(event_type, remote_domain, stream_id, sequence, payload, opts \\ []) do
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

  defp canonical_actor(username, domain, opts \\ []) do
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

  defp sign_snapshot(payload, key_id, secret)
       when is_map(payload) and is_binary(key_id) and is_binary(secret) do
    payload =
      payload
      |> Map.put_new("governance", %{"memberships" => [], "invites" => [], "bans" => []})
      |> Map.put_new("stream_positions", default_snapshot_stream_positions(payload))

    Map.put(payload, "signature", %{
      "algorithm" => "ed25519",
      "key_id" => key_id,
      "value" =>
        payload
        |> ArblargSDK.canonical_json_payload()
        |> ArblargSDK.sign_payload(secret)
    })
  end

  defp default_snapshot_stream_positions(%{"server" => %{"id" => server_id}})
       when is_binary(server_id) do
    [%{"stream_id" => "server:#{server_id}", "last_sequence" => 0}]
  end

  defp default_snapshot_stream_positions(_payload), do: []
end
