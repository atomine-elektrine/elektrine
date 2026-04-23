defmodule Elektrine.Messaging.FederationTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging

  alias Elektrine.Messaging.{
    ArblargProfiles,
    ArblargSDK,
    ChatConversation,
    ChatMessage,
    ChatMessageReaction,
    CommunityBan,
    Conversation,
    ConversationMember,
    Federation,
    Federation.Builders,
    Federation.Transport,
    Federation.Visibility,
    FederationAccountPresenceState,
    FederationDiscoveredPeer,
    FederationEvent,
    FederationExtensionEvent,
    FederationInviteState,
    FederationMembershipState,
    FederationOutboxEvent,
    FederationReadCursor,
    FederationRoomPresenceState,
    FederationStreamPosition,
    Server
  }

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

    test "includes remote-authored room messages in snapshot payloads" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "snapshot-room-participants"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "operations"
        })

      remote_message_id = "https://remote-b.example/_arblarg/messages/5001"

      %ChatMessage{}
      |> ChatMessage.changeset(%{
        conversation_id: channel.id,
        sender_id: nil,
        content: "hello from a remote participant",
        message_type: "text",
        federated_source: remote_message_id,
        origin_domain: "remote-b.example",
        media_metadata: %{
          "remote_sender" => canonical_actor("alice", "remote-b.example")
        }
      })
      |> Repo.insert!()

      assert {:ok, payload} =
               Federation.build_server_snapshot(server.id, messages_per_channel: 10)

      assert Enum.any?(payload["messages"], fn message ->
               message["id"] == remote_message_id and
                 message["content"] == "hello from a remote participant" and
                 get_in(message, ["sender", "handle"]) == "alice@remote-b.example"
             end)
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

    test "includes remote participant memberships in snapshot governance" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "snapshot-remote-members"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "operations"
        })

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote-b.example/users/alice",
          username: "alice",
          domain: "remote-b.example",
          inbox_url: "https://remote-b.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote-b.example",
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      assert {:ok, payload} =
               Federation.build_server_snapshot(server.id, messages_per_channel: 10)

      memberships = get_in(payload, ["governance", "memberships"]) || []

      assert Enum.any?(memberships, fn membership_payload ->
               get_in(membership_payload, ["membership", "actor", "handle"]) ==
                 "alice@remote-b.example" and
                 get_in(membership_payload, ["membership", "state"]) == "active"
             end)
    end

    test "includes multi-origin governance, reactions, read cursors, and extensions in snapshots" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "snapshot-multi-origin-state"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "operations"
        })

      remote_participant =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote-b.example/users/alice",
          username: "alice",
          domain: "remote-b.example",
          inbox_url: "https://remote-b.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      remote_banned =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote-c.example/users/bob",
          username: "bob",
          domain: "remote-c.example",
          inbox_url: "https://remote-c.example/users/bob/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      message =
        %ChatMessage{}
        |> ChatMessage.changeset(%{
          conversation_id: channel.id,
          sender_id: owner.id,
          content: "snapshot target",
          message_type: "text"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      server_federation_id =
        server.federation_id ||
          Elektrine.Messaging.Federation.Utils.server_federation_id(server.id)

      channel_federation_id =
        channel.federated_source ||
          Elektrine.Messaging.Federation.Utils.channel_federation_id(channel.id)

      message_federation_id =
        message.federated_source ||
          Elektrine.Messaging.Federation.Utils.message_federation_id(message.id)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_participant.id,
        origin_domain: "remote-b.example",
        role: "member",
        state: "invited",
        joined_at_remote: nil,
        updated_at_remote: timestamp,
        metadata: %{"join_request" => true, "source" => "snapshot-test"}
      })

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_banned.id,
        origin_domain: "remote-c.example",
        role: "member",
        state: "banned",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{
          "actor" => canonical_actor(owner.username, Federation.local_domain()),
          "ban_state" => "active",
          "reason" => "spam",
          "metadata" => %{"source" => "snapshot-ban"}
        }
      })

      Repo.insert!(%ChatMessageReaction{
        chat_message_id: message.id,
        remote_actor_id: remote_participant.id,
        emoji: ":wave:"
      })

      Repo.insert!(%FederationReadCursor{
        conversation_id: channel.id,
        chat_message_id: message.id,
        remote_actor_id: remote_participant.id,
        origin_domain: "remote-b.example",
        read_at: timestamp,
        read_through_sequence: 12
      })

      role_event_type = ArblargSDK.canonical_event_type("role.upsert")

      Repo.insert!(%FederationExtensionEvent{
        event_type: role_event_type,
        origin_domain: "remote-b.example",
        event_key: "role:urn:remote-b.example:roles:ops:channel:#{channel.id}",
        payload: %{
          "server" => %{"id" => server_federation_id},
          "channel" => %{"id" => channel_federation_id},
          "actor" => canonical_actor("alice", "remote-b.example"),
          "role" => %{
            "id" => "urn:remote-b.example:roles:ops",
            "name" => "Ops",
            "position" => 0,
            "permissions" => [],
            "updated_at" => DateTime.to_iso8601(timestamp)
          }
        },
        server_id: server.id,
        conversation_id: channel.id,
        occurred_at: timestamp
      })

      assert {:ok, payload} =
               Federation.build_server_snapshot(server.id, messages_per_channel: 10)

      memberships = get_in(payload, ["governance", "memberships"]) || []
      bans = get_in(payload, ["governance", "bans"]) || []
      reactions = payload["reactions"] || []
      read_cursors = payload["read_cursors"] || []
      extensions = payload["extensions"] || []

      assert Enum.any?(memberships, fn membership_payload ->
               get_in(membership_payload, ["membership", "actor", "handle"]) ==
                 "alice@remote-b.example" and
                 get_in(membership_payload, ["membership", "metadata", "join_request"]) == true
             end)

      assert Enum.any?(bans, fn ban_payload ->
               get_in(ban_payload, ["ban", "target", "handle"]) == "bob@remote-c.example" and
                 get_in(ban_payload, ["ban", "reason"]) == "spam" and
                 get_in(ban_payload, ["ban", "metadata", "source"]) == "snapshot-ban"
             end)

      assert Enum.any?(reactions, fn reaction_payload ->
               reaction_payload["message_id"] == message_federation_id and
                 get_in(reaction_payload, ["reaction", "actor", "handle"]) ==
                   "alice@remote-b.example"
             end)

      assert Enum.any?(read_cursors, fn cursor_payload ->
               cursor_payload["read_through_sequence"] == 12 and
                 get_in(cursor_payload, ["actor", "handle"]) == "alice@remote-b.example"
             end)

      assert Enum.any?(extensions, fn extension_payload ->
               extension_payload["event_type"] == role_event_type and
                 get_in(extension_payload, ["payload", "actor", "handle"]) ==
                   "alice@remote-b.example"
             end)
    end

    test "filters snapshot extensions to peers that advertise support" do
      owner = AccountsFixtures.user_fixture()

      {:ok, server} =
        Messaging.create_server(owner.id, %{name: "extension-snapshot", is_public: true})

      bootstrap_event_type = ArblargSDK.bootstrap_server_upsert_event_type()

      Repo.insert!(%FederationExtensionEvent{
        event_type: bootstrap_event_type,
        origin_domain: Federation.local_domain(),
        event_key: "bootstrap:#{server.id}",
        payload: %{"server" => %{"id" => "server-#{server.id}"}},
        server_id: server.id
      })

      bootstrap_peer = %{
        domain: "bootstrap.example",
        supported_event_types: [bootstrap_event_type]
      }

      core_only_peer = %{
        domain: "core-only.example",
        supported_event_types: ArblargSDK.core_event_types()
      }

      assert {:ok, full_snapshot} = Federation.build_server_snapshot(server.id)

      assert {:ok, bootstrap_snapshot} =
               Federation.build_server_snapshot(server.id, peer: bootstrap_peer)

      assert {:ok, core_only_snapshot} =
               Federation.build_server_snapshot(server.id, peer: core_only_peer)

      assert [%{"event_type" => ^bootstrap_event_type}] = full_snapshot["extensions"]
      assert [%{"event_type" => ^bootstrap_event_type}] = bootstrap_snapshot["extensions"]
      assert core_only_snapshot["extensions"] == []
    end

    test "exports only peer-visible channels and preserves channel policy metadata" do
      owner = AccountsFixtures.user_fixture()

      {:ok, server} =
        Messaging.create_server(owner.id, %{name: "visibility-snapshot", is_public: true})

      {:ok, public_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "lobby",
          description: "public room",
          is_public: true
        })

      {:ok, private_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "private room",
          is_public: false
        })

      private_channel =
        private_channel
        |> Conversation.changeset(%{approval_mode_enabled: true})
        |> Repo.update!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
      actor_payload = canonical_actor(owner.username, Federation.local_domain())
      target_payload = canonical_actor("alice", "remote.example")

      Repo.insert!(%FederationInviteState{
        conversation_id: private_channel.id,
        origin_domain: Federation.local_domain(),
        actor_uri: actor_payload["uri"],
        actor_payload: actor_payload,
        target_uri: target_payload["uri"],
        target_payload: target_payload,
        role: "member",
        state: "pending",
        invited_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{"source" => "snapshot-visibility-test"}
      })

      assert {:ok, invited_snapshot} =
               Federation.build_server_snapshot(server.id, peer: %{domain: "remote.example"})

      assert {:ok, stranger_snapshot} =
               Federation.build_server_snapshot(server.id, peer: %{domain: "stranger.example"})

      invited_names = Enum.map(invited_snapshot["channels"], & &1["name"])
      stranger_names = Enum.map(stranger_snapshot["channels"], & &1["name"])

      assert public_channel.name in invited_names
      assert private_channel.name in invited_names
      assert public_channel.name in stranger_names
      refute private_channel.name in stranger_names

      assert Enum.any?(invited_snapshot["channels"], fn channel ->
               channel["name"] == private_channel.name and
                 channel["is_public"] == false and
                 channel["approval_mode_enabled"] == true
             end)
    end

    test "does not expose private channels to banned remote invite targets" do
      owner = AccountsFixtures.user_fixture()

      {:ok, server} =
        Messaging.create_server(owner.id, %{name: "banned-visibility", is_public: true})

      {:ok, private_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "private room",
          is_public: false
        })

      private_channel =
        private_channel
        |> Conversation.changeset(%{approval_mode_enabled: true})
        |> Repo.update!()

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/alice",
          username: "alice",
          domain: "remote.example",
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
      actor_payload = canonical_actor(owner.username, Federation.local_domain())
      target_payload = canonical_actor("alice", "remote.example")

      Repo.insert!(%FederationInviteState{
        conversation_id: private_channel.id,
        origin_domain: Federation.local_domain(),
        actor_uri: actor_payload["uri"],
        actor_payload: actor_payload,
        target_uri: target_payload["uri"],
        target_payload: target_payload,
        role: "member",
        state: "pending",
        invited_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      Repo.insert!(%FederationMembershipState{
        conversation_id: private_channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "banned",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      assert {:ok, banned_snapshot} =
               Federation.build_server_snapshot(server.id, peer: %{domain: "remote.example"})

      refute Enum.any?(banned_snapshot["channels"], fn channel ->
               channel["name"] == private_channel.name
             end)
    end
  end

  describe "build_server_upsert_event/2" do
    test "exports only public channels in bootstrap payloads" do
      owner = AccountsFixtures.user_fixture()

      {:ok, server} =
        Messaging.create_server(owner.id, %{name: "bootstrap-public", is_public: true})

      {:ok, _public_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "announcements",
          description: "public room",
          is_public: true
        })

      {:ok, _private_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "staff",
          description: "private room",
          is_public: false,
          approval_mode_enabled: true
        })

      assert {:ok, event} = Builders.build_server_upsert_event(server.id, builder_context())

      channels = get_in(event, ["payload", "channels"])
      channel_names = Enum.map(channels, & &1["name"])

      refute "staff" in channel_names
      assert "announcements" in channel_names
      assert Enum.all?(channels, &(&1["is_public"] == true))
      assert Enum.any?(channels, &(&1["approval_mode_enabled"] == false))
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
            "id" => "https://remote.example/_arblarg/servers/42",
            "name" => "remote-hub",
            "description" => "Remote server",
            "is_public" => true,
            "member_count" => 12
          },
          "channels" => [
            %{
              "id" => "https://remote.example/_arblarg/channels/100",
              "name" => "general",
              "description" => "General remote chat",
              "topic" => "hello",
              "position" => 0
            }
          ],
          "messages" => [
            %{
              "id" => "https://remote.example/_arblarg/messages/5000",
              "channel_id" => "https://remote.example/_arblarg/channels/100",
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
          federated_source: "https://remote.example/_arblarg/channels/100"
        )

      assert mirror_channel
      assert mirror_channel.server_id == mirror_server.id
      assert mirror_channel.is_federated_mirror == true

      mirror_message =
        Repo.get_by(ChatMessage,
          conversation_id: mirror_channel.id,
          federated_source: "https://remote.example/_arblarg/messages/5000"
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
              m.federated_source == "https://remote.example/_arblarg/messages/5000",
          select: count()
        )
        |> Repo.one()

      assert mirror_count == 1

      # sanity checks for stored mirror server records
      stored_server = Repo.get(Server, mirror_server.id)
      assert stored_server.origin_domain == "remote.example"
    end

    test "imports room-origin snapshots that include participant-authored messages" do
      room_origin = "remote.example"
      participant_origin = "remote-b.example"
      channel_id = "https://remote.example/_arblarg/channels/200"
      participant_message_id = "https://remote-b.example/_arblarg/messages/2001"

      payload =
        %{
          "version" => 1,
          "origin_domain" => room_origin,
          "server" => %{
            "id" => "https://remote.example/_arblarg/servers/43",
            "name" => "remote-shared-room",
            "description" => "Remote shared room",
            "is_public" => true,
            "member_count" => 22
          },
          "channels" => [
            %{
              "id" => channel_id,
              "name" => "general",
              "description" => "General shared chat",
              "topic" => "hello",
              "position" => 0
            }
          ],
          "messages" => [
            %{
              "id" => participant_message_id,
              "channel_id" => channel_id,
              "content" => "participant hello",
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" => canonical_actor("alice", participant_origin)
            }
          ]
        }
        |> sign_snapshot("k1", "remote-example-secret")

      assert {:ok, mirror_server} = Federation.import_server_snapshot(payload, room_origin)

      mirror_channel =
        Repo.get_by(Conversation,
          type: "channel",
          federated_source: channel_id
        )

      assert mirror_channel.server_id == mirror_server.id

      assert participant_message =
               Repo.get_by(ChatMessage,
                 conversation_id: mirror_channel.id,
                 federated_source: participant_message_id
               )

      assert participant_message.content == "participant hello"
      assert participant_message.origin_domain == participant_origin
      assert participant_message.is_federated_mirror == true

      assert get_in(participant_message.media_metadata, ["remote_sender", "handle"]) ==
               "alice@remote-b.example"
    end

    test "imports room-origin snapshots that include participant memberships" do
      room_origin = "remote.example"
      participant_origin = "remote-b.example"
      channel_id = "https://remote.example/_arblarg/channels/220"
      participant_uri = "https://remote-b.example/users/alice"

      payload =
        %{
          "version" => 1,
          "origin_domain" => room_origin,
          "server" => %{
            "id" => "https://remote.example/_arblarg/servers/44",
            "name" => "remote-shared-room",
            "description" => "Remote shared room",
            "is_public" => true,
            "member_count" => 22
          },
          "channels" => [
            %{
              "id" => channel_id,
              "name" => "general",
              "description" => "General shared chat",
              "topic" => "hello",
              "position" => 0
            }
          ],
          "governance" => %{
            "memberships" => [
              %{
                "refs" => %{
                  "server_id" => "https://remote.example/_arblarg/servers/44",
                  "channel_id" => channel_id
                },
                "membership" => %{
                  "actor" => canonical_actor("alice", participant_origin, uri: participant_uri),
                  "role" => "member",
                  "state" => "active",
                  "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                  "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                  "metadata" => %{}
                }
              }
            ],
            "invites" => [],
            "bans" => []
          }
        }
        |> sign_snapshot("k1", "remote-example-secret")

      assert {:ok, _mirror_server} = Federation.import_server_snapshot(payload, room_origin)

      mirror_channel =
        Repo.get_by(Conversation,
          type: "channel",
          federated_source: channel_id
        )

      remote_actor = Repo.get_by(Actor, uri: participant_uri)

      assert %FederationMembershipState{state: "active", role: "member"} =
               Repo.get_by(FederationMembershipState,
                 conversation_id: mirror_channel.id,
                 remote_actor_id: remote_actor.id
               )
    end

    test "imports room-origin snapshots that include participant governance, reactions, read cursors, and extensions" do
      room_origin = "remote.example"
      participant_origin = "remote-b.example"
      banned_origin = "remote-c.example"
      server_id = "https://remote.example/_arblarg/servers/45"
      channel_id = "https://remote.example/_arblarg/channels/221"
      message_id = "https://remote.example/_arblarg/messages/2210"
      role_event_type = ArblargSDK.canonical_event_type("role.upsert")
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      payload =
        %{
          "version" => 1,
          "origin_domain" => room_origin,
          "server" => %{
            "id" => server_id,
            "name" => "remote-shared-room",
            "description" => "Remote shared room",
            "is_public" => true,
            "member_count" => 22
          },
          "channels" => [
            %{
              "id" => channel_id,
              "name" => "general",
              "description" => "General shared chat",
              "topic" => "hello",
              "position" => 0
            }
          ],
          "messages" => [
            %{
              "id" => message_id,
              "channel_id" => channel_id,
              "content" => "snapshot target",
              "message_type" => "text",
              "attachments" => [],
              "sender" => canonical_actor("host", room_origin)
            }
          ],
          "governance" => %{
            "memberships" => [
              %{
                "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
                "membership" => %{
                  "actor" => canonical_actor("host", room_origin),
                  "role" => "admin",
                  "state" => "active",
                  "joined_at" => DateTime.to_iso8601(timestamp),
                  "updated_at" => DateTime.to_iso8601(timestamp),
                  "metadata" => %{"source" => "snapshot-admin-membership"}
                }
              },
              %{
                "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
                "membership" => %{
                  "actor" => canonical_actor("alice", participant_origin),
                  "role" => "member",
                  "state" => "active",
                  "joined_at" => DateTime.to_iso8601(timestamp),
                  "updated_at" => DateTime.to_iso8601(timestamp),
                  "metadata" => %{"source" => "snapshot-membership"}
                }
              }
            ],
            "invites" => [],
            "bans" => [
              %{
                "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
                "ban" => %{
                  "actor" => canonical_actor("host", room_origin),
                  "target" => canonical_actor("bob", banned_origin),
                  "state" => "active",
                  "reason" => "spam",
                  "banned_at" => DateTime.to_iso8601(timestamp),
                  "updated_at" => DateTime.to_iso8601(timestamp),
                  "metadata" => %{"source" => "snapshot-ban"}
                }
              }
            ]
          },
          "reactions" => [
            %{
              "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
              "message_id" => message_id,
              "reaction" => %{
                "emoji" => ":wave:",
                "actor" => canonical_actor("alice", participant_origin)
              }
            }
          ],
          "read_cursors" => [
            %{
              "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
              "read_through_message_id" => message_id,
              "read_through_sequence" => 9,
              "actor" => canonical_actor("alice", participant_origin),
              "read_at" => DateTime.to_iso8601(timestamp)
            }
          ],
          "extensions" => [
            %{
              "event_type" => role_event_type,
              "payload" => %{
                "server" => %{"id" => server_id},
                "channel" => %{"id" => channel_id},
                "actor" => canonical_actor("host", room_origin),
                "role" => %{
                  "id" => "urn:remote-b.example:roles:ops",
                  "name" => "Ops",
                  "position" => 0,
                  "permissions" => [],
                  "updated_at" => DateTime.to_iso8601(timestamp)
                }
              }
            }
          ]
        }
        |> sign_snapshot("k1", "remote-example-secret")

      assert {:ok, mirror_server} = Federation.import_server_snapshot(payload, room_origin)

      mirror_channel =
        Repo.get_by!(Conversation,
          type: "channel",
          federated_source: channel_id
        )

      assert mirror_channel.server_id == mirror_server.id

      mirror_message =
        Repo.get_by!(ChatMessage,
          conversation_id: mirror_channel.id,
          federated_source: message_id
        )

      participant_actor =
        Repo.get_by!(Actor, uri: "https://remote-b.example/users/alice")

      banned_actor =
        Repo.get_by!(Actor, uri: "https://remote-c.example/users/bob")

      assert %FederationMembershipState{metadata: membership_metadata} =
               Repo.get_by(FederationMembershipState,
                 conversation_id: mirror_channel.id,
                 remote_actor_id: participant_actor.id,
                 state: "active"
               )

      assert membership_metadata["source"] == "snapshot-membership"

      assert Repo.get_by(ChatMessageReaction,
               chat_message_id: mirror_message.id,
               remote_actor_id: participant_actor.id,
               emoji: ":wave:"
             )

      assert %FederationReadCursor{read_through_sequence: 9} =
               Repo.get_by(FederationReadCursor,
                 conversation_id: mirror_channel.id,
                 remote_actor_id: participant_actor.id
               )

      assert %FederationMembershipState{state: "banned", metadata: banned_metadata} =
               Repo.get_by(FederationMembershipState,
                 conversation_id: mirror_channel.id,
                 remote_actor_id: banned_actor.id
               )

      assert banned_metadata["reason"] == "spam"
      assert banned_metadata["metadata"]["source"] == "snapshot-ban"

      assert Repo.get_by(FederationExtensionEvent,
               event_type: role_event_type,
               event_key: "role:urn:remote-b.example:roles:ops:channel:#{mirror_channel.id}"
             )
    end

    test "rejects conflicting server ownership for an already-mirrored federation id" do
      payload =
        %{
          "version" => 1,
          "origin_domain" => "remote-a.example",
          "server" => %{
            "id" => "https://remote-a.example/_arblarg/servers/42",
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
          federation_id: "https://remote-a.example/_arblarg/servers/42",
          origin_domain: "different-origin.example",
          is_federated_mirror: true
        })
        |> Repo.insert()

      assert {:error, :federation_origin_conflict} =
               Federation.import_server_snapshot(payload, "remote-a.example")
    end

    test "preserves mirrored channel visibility and approval policy from snapshot payloads" do
      channel_id = "https://remote.example/_arblarg/channels/201"

      payload =
        %{
          "version" => 1,
          "origin_domain" => "remote.example",
          "server" => %{
            "id" => "https://remote.example/_arblarg/servers/200",
            "name" => "remote-private",
            "description" => "Remote private server",
            "is_public" => false,
            "member_count" => 4
          },
          "channels" => [
            %{
              "id" => channel_id,
              "name" => "staff",
              "position" => 0,
              "is_public" => false,
              "approval_mode_enabled" => true
            }
          ],
          "messages" => []
        }
        |> sign_snapshot("k1", "remote-example-secret")

      assert {:ok, _mirror_server} = Federation.import_server_snapshot(payload, "remote.example")

      assert %Conversation{
               is_public: false,
               approval_mode_enabled: true,
               federated_source: ^channel_id
             } = Repo.get_by(Conversation, federated_source: channel_id)
    end

    test "stores multi-origin stream checkpoints from snapshots for later live events" do
      room_origin = "remote-a.example"
      participant_origin = "remote-b.example"
      server_id = "https://remote-a.example/_arblarg/servers/410"
      channel_id = "https://remote-a.example/_arblarg/channels/411"
      channel_stream = "channel:#{channel_id}"
      participant_uri = "https://remote-b.example/users/alice"

      payload =
        %{
          "version" => 1,
          "origin_domain" => room_origin,
          "server" => %{
            "id" => server_id,
            "name" => "room-origin",
            "description" => "Imported multi-origin room",
            "is_public" => true,
            "member_count" => 2
          },
          "channels" => [
            %{
              "id" => channel_id,
              "name" => "general",
              "position" => 0,
              "is_public" => true
            }
          ],
          "messages" => [],
          "governance" => %{
            "memberships" => [
              %{
                "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
                "membership" => %{
                  "actor" => canonical_actor("alice", participant_origin, uri: participant_uri),
                  "role" => "member",
                  "state" => "active",
                  "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                  "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                  "metadata" => %{}
                }
              }
            ],
            "invites" => [],
            "bans" => []
          },
          "stream_positions" => [
            %{
              "origin_domain" => room_origin,
              "stream_id" => "server:#{server_id}",
              "last_sequence" => 1
            },
            %{
              "origin_domain" => room_origin,
              "stream_id" => channel_stream,
              "last_sequence" => 1
            },
            %{
              "origin_domain" => participant_origin,
              "stream_id" => channel_stream,
              "last_sequence" => 2
            }
          ]
        }
        |> sign_snapshot("k1", "remote-a-secret")

      assert {:ok, _mirror_server} = Federation.import_server_snapshot(payload, room_origin)

      assert %FederationStreamPosition{last_sequence: 2} =
               Repo.get_by(FederationStreamPosition,
                 origin_domain: participant_origin,
                 stream_id: channel_stream
               )

      participant_event =
        signed_event(
          "message.create",
          participant_origin,
          channel_stream,
          3,
          %{
            "server" => %{"id" => server_id, "name" => "room-origin", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "message" => %{
              "id" => "https://remote-b.example/_arblarg/messages/9001",
              "channel_id" => channel_id,
              "content" => "hello after snapshot",
              "message_type" => "text",
              "attachments" => [],
              "sender" => canonical_actor("alice", participant_origin, uri: participant_uri)
            }
          },
          secret: "remote-b-secret"
        )

      assert {:ok, :applied} = Federation.receive_event(participant_event, participant_origin)

      assert Repo.get_by(ChatMessage,
               federated_source: "https://remote-b.example/_arblarg/messages/9001"
             )
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
      path = "/_arblarg/events"
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
               "/_arblarg/sync",
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
      path = "/_arblarg/events"
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
      path = "/_arblarg/events"
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
      server_id = "https://remote.example/_arblarg/servers/501"
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
          "server:https://remote.example/_arblarg/servers/901",
          1,
          %{
            "server" => %{
              "id" => "https://remote.example/_arblarg/servers/901",
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
          "server:https://remote-b.example/_arblarg/servers/902",
          1,
          %{
            "server" => %{
              "id" => "https://remote-b.example/_arblarg/servers/902",
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
      server_id = "https://remote.example/_arblarg/servers/700"
      channel_id = "https://remote.example/_arblarg/channels/701"
      message_id = "https://remote.example/_arblarg/messages/702"
      stream_id = "channel:#{channel_id}"

      membership_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "membership" => %{
              "actor" => canonical_actor("alice", remote_domain),
              "role" => "member",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(membership_event, remote_domain)

      create_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          2,
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
          3,
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
          4,
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

    test "accepts participant-authored messages in a local room after membership is established" do
      owner = AccountsFixtures.user_fixture()
      remote_domain = "remote.example"
      {:ok, server} = Messaging.create_server(owner.id, %{name: "local-shared-room"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "shared",
          description: "local shared room"
        })

      {:ok, snapshot} = Federation.build_server_snapshot(server.id, messages_per_channel: 1)
      local_server_id = get_in(snapshot, ["server", "id"])

      local_channel_id =
        snapshot["channels"]
        |> Enum.find(&(&1["name"] == "shared"))
        |> Map.fetch!("id")

      stream_id = "channel:#{local_channel_id}"
      actor_payload = canonical_actor("alice", remote_domain)

      unauthorized_message_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          1,
          %{
            "refs" => %{"server_id" => local_server_id, "channel_id" => local_channel_id},
            "message" => %{
              "id" => "https://remote.example/_arblarg/messages/7771",
              "channel_id" => local_channel_id,
              "content" => "blocked before join",
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" => actor_payload
            }
          }
        )

      assert {:error, :not_authorized_for_room} =
               Federation.receive_event(unauthorized_message_event, remote_domain)

      membership_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "refs" => %{"server_id" => local_server_id, "channel_id" => local_channel_id},
            "membership" => %{
              "actor" => actor_payload,
              "role" => "member",
              "state" => "invited",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(membership_event, remote_domain)

      message_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          2,
          %{
            "refs" => %{"server_id" => local_server_id, "channel_id" => local_channel_id},
            "message" => %{
              "id" => "https://remote.example/_arblarg/messages/7772",
              "channel_id" => local_channel_id,
              "content" => "joined and talking",
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" => actor_payload
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(message_event, remote_domain)

      assert %FederationMembershipState{state: "active"} =
               Repo.get_by(FederationMembershipState,
                 conversation_id: channel.id
               )

      assert inbound_message =
               Repo.get_by(ChatMessage,
                 conversation_id: channel.id,
                 federated_source: "https://remote.example/_arblarg/messages/7772"
               )

      assert inbound_message.content == "joined and talking"
      assert inbound_message.is_federated_mirror == false
      assert inbound_message.origin_domain == remote_domain

      assert get_in(inbound_message.media_metadata, ["remote_sender", "handle"]) ==
               "alice@remote.example"
    end

    test "rejects direct remote activation in a local room without acceptance" do
      owner = AccountsFixtures.user_fixture()
      remote_domain = "remote.example"
      {:ok, server} = Messaging.create_server(owner.id, %{name: "strict-local-room"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "shared",
          description: "local shared room"
        })

      {:ok, snapshot} = Federation.build_server_snapshot(server.id, messages_per_channel: 1)
      local_server_id = get_in(snapshot, ["server", "id"])
      local_channel_id = get_in(snapshot, ["channels", Access.at(0), "id"])

      activation_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          "channel:#{local_channel_id}",
          1,
          %{
            "refs" => %{"server_id" => local_server_id, "channel_id" => local_channel_id},
            "membership" => %{
              "actor" => canonical_actor("alice", remote_domain),
              "role" => "member",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      assert {:error, :not_authorized_for_room} =
               Federation.receive_event(activation_event, remote_domain)

      refute Repo.get_by(FederationMembershipState, conversation_id: channel.id)
    end

    test "rejects governance events in a local room when the remote actor lacks room permissions" do
      owner = AccountsFixtures.user_fixture()
      remote_domain = "remote.example"
      {:ok, server} = Messaging.create_server(owner.id, %{name: "local-governance-room"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "shared",
          description: "local shared room"
        })

      {:ok, snapshot} = Federation.build_server_snapshot(server.id, messages_per_channel: 1)
      local_server_id = get_in(snapshot, ["server", "id"])
      local_channel_id = get_in(snapshot, ["channels", Access.at(0), "id"])

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://#{remote_domain}/users/alice",
          username: "alice",
          domain: remote_domain,
          inbox_url: "https://#{remote_domain}/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: remote_domain,
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      role_event =
        signed_event(
          "role.upsert",
          remote_domain,
          "channel:#{local_channel_id}",
          1,
          %{
            "server" => %{"id" => local_server_id, "name" => server.name, "is_public" => true},
            "channel" => %{"id" => local_channel_id, "name" => channel.name, "position" => 0},
            "refs" => %{"server_id" => local_server_id, "channel_id" => local_channel_id},
            "actor" => canonical_actor("alice", remote_domain, uri: remote_actor.uri),
            "role" => %{
              "id" => "role-ops",
              "name" => "Ops",
              "position" => 1,
              "permissions" => ["manage_roles"]
            }
          }
        )

      assert {:error, :not_authorized_for_room} =
               Federation.receive_event(role_event, remote_domain)

      refute Repo.get_by(FederationExtensionEvent,
               event_type: ArblargSDK.canonical_event_type("role.upsert"),
               event_key: "role:role-ops:channel:#{channel.id}"
             )
    end

    test "grants remote admins governance permissions in a local room ACL" do
      owner = AccountsFixtures.user_fixture()
      remote_domain = "remote.example"
      {:ok, server} = Messaging.create_server(owner.id, %{name: "local-governance-admin-room"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "shared",
          description: "local shared room"
        })

      {:ok, snapshot} = Federation.build_server_snapshot(server.id, messages_per_channel: 1)
      local_server_id = get_in(snapshot, ["server", "id"])
      local_channel_id = get_in(snapshot, ["channels", Access.at(0), "id"])

      suffix = System.unique_integer([:positive])

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://#{remote_domain}/users/mod-#{suffix}",
          username: "mod-#{suffix}",
          domain: remote_domain,
          inbox_url: "https://#{remote_domain}/users/mod-#{suffix}/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: remote_domain,
        role: "admin",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      role_event =
        signed_event(
          "role.upsert",
          remote_domain,
          "channel:#{local_channel_id}",
          1,
          %{
            "server" => %{"id" => local_server_id, "name" => server.name, "is_public" => true},
            "channel" => %{"id" => local_channel_id, "name" => channel.name, "position" => 0},
            "refs" => %{"server_id" => local_server_id, "channel_id" => local_channel_id},
            "actor" => canonical_actor("mod-#{suffix}", remote_domain, uri: remote_actor.uri),
            "role" => %{
              "id" => "role-ops",
              "name" => "Ops",
              "position" => 1,
              "permissions" => ["manage_roles"]
            }
          }
        )

      assert :ok =
               Elektrine.Messaging.RoomACL.authorize_remote_actor_action(
                 channel,
                 remote_actor.id,
                 :role_upsert,
                 %{remote_actor_id: remote_actor.id}
               )

      assert :ok = ArblargSDK.validate_event_envelope(role_event)
    end

    test "materializes accepted invites for local users in mirrored rooms" do
      local_user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()
      server = Repo.get!(Server, channel.server_id)
      stream_id = "channel:#{channel.federated_source}"
      local_domain = Federation.local_domain()
      suffix = System.unique_integer([:positive])

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/mod-#{suffix}",
          username: "mod-#{suffix}",
          domain: "remote.example",
          inbox_url: "https://remote.example/users/mod-#{suffix}/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "admin",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      invite_event =
        signed_event(
          "invite.upsert",
          "remote.example",
          stream_id,
          1,
          %{
            "server" => %{
              "id" => server.federation_id,
              "name" => server.name,
              "is_public" => true
            },
            "channel" => %{
              "id" => channel.federated_source,
              "name" => channel.name,
              "position" => 0
            },
            "invite" => %{
              "actor" =>
                canonical_actor("mod-#{suffix}", "remote.example", uri: remote_actor.uri),
              "target" =>
                canonical_actor(local_user.username, local_domain,
                  uri: "https://#{local_domain}/users/#{local_user.username}"
                ),
              "role" => "member",
              "state" => "accepted",
              "invited_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(invite_event, "remote.example")

      assert %ConversationMember{} =
               Repo.get_by(ConversationMember,
                 conversation_id: channel.id,
                 user_id: local_user.id
               )

      assert Repo.get_by(FederationInviteState,
               conversation_id: channel.id,
               target_uri: "https://#{local_domain}/users/#{local_user.username}",
               state: "accepted"
             )
    end

    test "applies reaction add and remove events" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/_arblarg/servers/800"
      channel_id = "https://remote.example/_arblarg/channels/801"
      message_id = "https://remote.example/_arblarg/messages/802"
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

      membership_bob_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "membership" => %{
              "actor" => canonical_actor("bob", remote_domain),
              "role" => "member",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      membership_alice_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          2,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "membership" => %{
              "actor" => canonical_actor("alice", remote_domain, uri: actor_uri),
              "role" => "member",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(membership_bob_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(membership_alice_event, remote_domain)

      create_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          3,
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
          4,
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
          5,
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
      server_id = "https://remote.example/_arblarg/servers/810"
      channel_id = "https://remote.example/_arblarg/channels/811"
      message_id = "https://remote.example/_arblarg/messages/812"
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

      membership_bob_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "membership" => %{
              "actor" => canonical_actor("bob", remote_domain),
              "role" => "member",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      membership_alice_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          2,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "membership" => %{
              "actor" => canonical_actor("alice", remote_domain, uri: existing_uri),
              "role" => "member",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(membership_bob_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(membership_alice_event, remote_domain)

      create_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          3,
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
          4,
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

      assert {:error, :invalid_actor} =
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
      server_id = "https://remote.example/_arblarg/servers/900"
      channel_id = "https://remote.example/_arblarg/channels/901"
      message_id = "https://remote.example/_arblarg/messages/902"
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

      membership_bob_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "membership" => %{
              "actor" => canonical_actor("bob", remote_domain),
              "role" => "member",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      membership_reader_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          2,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "membership" => %{
              "actor" => canonical_actor("reader", remote_domain, uri: actor_uri),
              "role" => "member",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          }
        )

      assert {:ok, :applied} = Federation.receive_event(membership_bob_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(membership_reader_event, remote_domain)

      create_event =
        signed_event(
          "message.create",
          remote_domain,
          stream_id,
          3,
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
          4,
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
      server_id = "https://remote.example/_arblarg/servers/910"
      channel_id = "https://remote.example/_arblarg/channels/911"
      stream_id = "channel:#{channel_id}"

      membership_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "membership" => %{
              "actor" => canonical_actor("mod", remote_domain),
              "role" => "admin",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{"source" => "test"}
            }
          }
        )

      invite_event =
        signed_event(
          "invite.upsert",
          remote_domain,
          stream_id,
          2,
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

      assert {:ok, :applied} = Federation.receive_event(membership_event, remote_domain)

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
          3,
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

    test "rejects invite governance from non-moderator participants" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "local-authority-room"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "governed locally"
        })

      {:ok, snapshot} = Federation.build_server_snapshot(server.id, messages_per_channel: 1)
      server_id = snapshot["server"]["id"]
      channel_id = get_in(snapshot, ["channels", Access.at(0), "id"])
      remote_domain = "remote-b.example"

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://#{remote_domain}/users/alice",
          username: "alice",
          domain: remote_domain,
          inbox_url: "https://#{remote_domain}/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: remote_domain,
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      invite_event =
        signed_event(
          "invite.upsert",
          remote_domain,
          "channel:#{channel_id}",
          1,
          %{
            "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
            "invite" => %{
              "actor" => canonical_actor("alice", remote_domain),
              "target" => canonical_actor("bob", remote_domain),
              "role" => "member",
              "state" => "pending",
              "invited_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{"source" => "participant"}
            }
          },
          secret: "test-shared-secret-b"
        )

      assert {:error, :not_authorized_for_room} =
               Federation.receive_event(invite_event, remote_domain)

      refute Repo.get_by(FederationInviteState, conversation_id: channel.id)
    end

    test "persists remote bans targeting local users and exports them in snapshots" do
      owner = AccountsFixtures.user_fixture()
      local_user = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "local-ban-room"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "ban target",
          is_public: true
        })

      assert {:ok, _member} = Messaging.join_channel(channel.id, local_user.id)

      server_id =
        server.federation_id ||
          Elektrine.Messaging.Federation.Utils.server_federation_id(server.id)

      channel_id =
        channel.federated_source ||
          Elektrine.Messaging.Federation.Utils.channel_federation_id(channel.id)

      remote_domain = "remote-b.example"

      remote_moderator =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://#{remote_domain}/users/mod",
          username: "mod",
          domain: remote_domain,
          inbox_url: "https://#{remote_domain}/users/mod/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_moderator.id,
        origin_domain: remote_domain,
        role: "owner",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      banned_at = DateTime.utc_now() |> DateTime.truncate(:second)

      ban_event =
        signed_event(
          "ban.upsert",
          remote_domain,
          "channel:#{channel_id}",
          1,
          %{
            "server" => %{"id" => server_id, "name" => server.name, "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => channel.name, "position" => 0},
            "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
            "ban" => %{
              "actor" => canonical_actor("mod", remote_domain),
              "target" => canonical_actor(local_user.username, Federation.local_domain()),
              "state" => "active",
              "reason" => "spam",
              "banned_at" => DateTime.to_iso8601(banned_at),
              "updated_at" => DateTime.to_iso8601(banned_at),
              "metadata" => %{"source" => "remote-ban"}
            }
          },
          secret: "test-shared-secret-b"
        )

      assert {:ok, :applied} = Federation.receive_event(ban_event, remote_domain)

      assert %CommunityBan{} =
               ban =
               Repo.get_by(CommunityBan,
                 conversation_id: channel.id,
                 user_id: local_user.id
               )

      assert ban.origin_domain == remote_domain
      assert get_in(ban.actor_payload, ["handle"]) == "mod@remote-b.example"
      assert ban.reason == "spam"
      assert ban.banned_at_remote == banned_at
      assert ban.metadata == %{"source" => "remote-ban"}

      refute Repo.exists?(
               from(member in ConversationMember,
                 where:
                   member.conversation_id == ^channel.id and member.user_id == ^local_user.id and
                     is_nil(member.left_at)
               )
             )

      assert {:error, :banned} = Messaging.join_channel(channel.id, local_user.id)

      assert {:ok, payload} = Federation.build_server_snapshot(server.id, messages_per_channel: 1)

      bans = get_in(payload, ["governance", "bans"]) || []

      assert Enum.any?(bans, fn item ->
               get_in(item, ["ban", "target", "handle"]) ==
                 "#{local_user.username}@#{Federation.local_domain()}" and
                 get_in(item, ["ban", "actor", "handle"]) == "mod@remote-b.example" and
                 get_in(item, ["ban", "reason"]) == "spam"
             end)
    end

    test "enforces federated role assignments and permission overwrites for participant writes" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "local-acl-room"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "shared acl"
        })

      server_id =
        server.federation_id ||
          Elektrine.Messaging.Federation.Utils.server_federation_id(server.id)

      channel_id =
        channel.federated_source ||
          Elektrine.Messaging.Federation.Utils.channel_federation_id(channel.id)

      remote_domain = "remote-b.example"

      writer_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://#{remote_domain}/users/alice",
          username: "alice",
          domain: remote_domain,
          inbox_url: "https://#{remote_domain}/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      admin_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://#{remote_domain}/users/mod",
          username: "mod",
          domain: remote_domain,
          inbox_url: "https://#{remote_domain}/users/mod/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: writer_actor.id,
        origin_domain: remote_domain,
        role: "readonly",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: admin_actor.id,
        origin_domain: remote_domain,
        role: "admin",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      role_upsert_event =
        signed_event(
          "role.upsert",
          remote_domain,
          "channel:#{channel_id}",
          1,
          %{
            "server" => %{"id" => server_id, "name" => server.name, "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => channel.name, "position" => 0},
            "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
            "actor" => canonical_actor("mod", remote_domain),
            "role" => %{
              "id" => "role:speaker",
              "name" => "Speaker",
              "permissions" => ["send_messages"],
              "position" => 20
            }
          },
          secret: "test-shared-secret-b"
        )

      role_assignment_event =
        signed_event(
          "role.assignment.upsert",
          remote_domain,
          "channel:#{channel_id}",
          2,
          %{
            "server" => %{"id" => server_id, "name" => server.name, "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => channel.name, "position" => 0},
            "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
            "actor" => canonical_actor("mod", remote_domain),
            "assignment" => %{
              "role_id" => "role:speaker",
              "target" => %{"type" => "member", "id" => writer_actor.uri},
              "state" => "assigned"
            }
          },
          secret: "test-shared-secret-b"
        )

      assert {:ok, :applied} = Federation.receive_event(role_upsert_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(role_assignment_event, remote_domain)

      create_event =
        signed_event(
          "message.create",
          remote_domain,
          "channel:#{channel_id}",
          3,
          %{
            "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
            "message" => %{
              "id" => "https://#{remote_domain}/_arblarg/messages/1",
              "channel_id" => channel_id,
              "sender" => canonical_actor("alice", remote_domain, uri: writer_actor.uri),
              "content" => "allowed by role assignment",
              "message_type" => "text",
              "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          },
          secret: "test-shared-secret-b"
        )

      assert {:ok, :applied} = Federation.receive_event(create_event, remote_domain)

      overwrite_event =
        signed_event(
          "permission.overwrite.upsert",
          remote_domain,
          "channel:#{channel_id}",
          4,
          %{
            "server" => %{"id" => server_id, "name" => server.name, "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => channel.name, "position" => 0},
            "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
            "actor" => canonical_actor("mod", remote_domain),
            "overwrite" => %{
              "id" => "deny-send",
              "target" => %{"type" => "member", "id" => writer_actor.uri},
              "allow" => [],
              "deny" => ["send_messages"]
            }
          },
          secret: "test-shared-secret-b"
        )

      assert {:ok, :applied} = Federation.receive_event(overwrite_event, remote_domain)

      blocked_event =
        signed_event(
          "message.create",
          remote_domain,
          "channel:#{channel_id}",
          5,
          %{
            "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
            "message" => %{
              "id" => "https://#{remote_domain}/_arblarg/messages/2",
              "channel_id" => channel_id,
              "sender" => canonical_actor("alice", remote_domain, uri: writer_actor.uri),
              "content" => "blocked by overwrite",
              "message_type" => "text",
              "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          },
          secret: "test-shared-secret-b"
        )

      assert {:error, :not_authorized_for_room} =
               Federation.receive_event(blocked_event, remote_domain)
    end

    test "accepts participant thread events for mirrored rooms" do
      channel = mirrored_channel_fixture()
      server = Repo.get!(Server, channel.server_id)
      remote_domain = "remote-b.example"
      stream_id = "channel:#{channel.federated_source}"

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://#{remote_domain}/users/alice",
          username: "alice",
          domain: remote_domain,
          inbox_url: "https://#{remote_domain}/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: remote_domain,
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      thread_event =
        signed_event(
          "thread.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{
              "id" => server.federation_id,
              "name" => server.name,
              "is_public" => true
            },
            "channel" => %{
              "id" => channel.federated_source,
              "name" => channel.name,
              "position" => channel.channel_position || 0
            },
            "thread" => %{
              "id" => "thread-remote-b",
              "channel_id" => channel.federated_source,
              "name" => "Not allowed",
              "state" => "active",
              "owner" => canonical_actor("alice", remote_domain)
            }
          },
          secret: "test-shared-secret-b"
        )

      assert {:ok, :applied} = Federation.receive_event(thread_event, remote_domain)

      assert Repo.get_by(FederationExtensionEvent,
               event_type: ArblargSDK.canonical_event_type("thread.upsert"),
               event_key: "thread:thread-remote-b:channel:#{channel.id}"
             )
    end

    test "rejects participant role changes without admin room role" do
      channel = mirrored_channel_fixture()
      server = Repo.get!(Server, channel.server_id)
      remote_domain = "remote-b.example"
      stream_id = "channel:#{channel.federated_source}"

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://#{remote_domain}/users/alice",
          username: "alice",
          domain: remote_domain,
          inbox_url: "https://#{remote_domain}/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: remote_domain,
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      role_event =
        signed_event(
          "role.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{
              "id" => server.federation_id,
              "name" => server.name,
              "is_public" => true
            },
            "channel" => %{
              "id" => channel.federated_source,
              "name" => channel.name,
              "position" => channel.channel_position || 0
            },
            "actor" => canonical_actor("alice", remote_domain),
            "role" => %{
              "id" => "role-ops",
              "name" => "Ops",
              "position" => 1,
              "permissions" => ["manage_messages"]
            }
          },
          secret: "test-shared-secret-b"
        )

      assert {:error, :not_authorized_for_room} =
               Federation.receive_event(role_event, remote_domain)

      refute Repo.get_by(FederationExtensionEvent,
               event_type: ArblargSDK.canonical_event_type("role.upsert"),
               event_key: "role:role-ops:channel:#{channel.id}"
             )
    end

    test "rejects elevated participant membership roles in mirrored rooms" do
      channel = mirrored_channel_fixture()
      server = Repo.get!(Server, channel.server_id)
      remote_domain = "remote-b.example"
      stream_id = "channel:#{channel.federated_source}"

      membership_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          stream_id,
          1,
          %{
            "server" => %{
              "id" => server.federation_id,
              "name" => server.name,
              "is_public" => true
            },
            "channel" => %{
              "id" => channel.federated_source,
              "name" => channel.name,
              "position" => channel.channel_position || 0
            },
            "membership" => %{
              "actor" => canonical_actor("alice", remote_domain),
              "role" => "admin",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{}
            }
          },
          secret: "test-shared-secret-b"
        )

      assert {:error, :invalid_event_payload} =
               Federation.receive_event(membership_event, remote_domain)

      refute Repo.get_by(FederationMembershipState, conversation_id: channel.id)
    end

    test "applies extension events and surfaces projections for chat UI" do
      remote_domain = "remote.example"
      server_id = "https://remote.example/_arblarg/servers/990"
      channel_id = "https://remote.example/_arblarg/channels/991"
      channel_stream = "channel:#{channel_id}"
      actor_uri = "https://remote.example/users/modbot"
      subscriber = AccountsFixtures.user_fixture()

      {:ok, actor} =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "modbot",
          domain: remote_domain,
          inbox_url: "#{actor_uri}/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert()

      Repo.insert!(
        %Elektrine.Profiles.Follow{}
        |> Elektrine.Profiles.Follow.changeset(%{
          follower_id: subscriber.id,
          remote_actor_id: actor.id,
          pending: false
        })
      )

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

      membership_event =
        signed_event(
          "membership.upsert",
          remote_domain,
          channel_stream,
          1,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "membership" => %{
              "actor" => canonical_actor("modbot", remote_domain, uri: actor_uri),
              "role" => "admin",
              "state" => "active",
              "joined_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "metadata" => %{"source" => "presence-test"}
            }
          }
        )

      role_upsert_event =
        signed_event(
          "role.upsert",
          remote_domain,
          channel_stream,
          2,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "actor" => canonical_actor("modbot", remote_domain, uri: actor_uri),
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
          3,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "actor" => canonical_actor("modbot", remote_domain, uri: actor_uri),
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
          4,
          %{
            "server" => %{"id" => server_id, "name" => "remote", "is_public" => true},
            "channel" => %{"id" => channel_id, "name" => "general", "position" => 0},
            "actor" => canonical_actor("modbot", remote_domain, uri: actor_uri),
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
          5,
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
          6,
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
          7,
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

      presence_update_item = %{
        "event_type" => "presence.update",
        "origin_domain" => remote_domain,
        "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "payload" => %{
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
      }

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{subscriber.id}")

      assert {:ok, :applied} = Federation.receive_event(membership_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(role_upsert_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(role_assignment_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(permission_overwrite_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(thread_upsert_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(thread_archive_event, remote_domain)
      assert {:ok, :applied} = Federation.receive_event(moderation_action_event, remote_domain)

      assert {:ok, %{"counts" => %{"applied" => 1}}} =
               Federation.receive_ephemeral_batch(
                 %{"items" => [presence_update_item]},
                 remote_domain
               )

      mirror_server = Repo.get_by(Server, federation_id: server_id)
      mirror_channel = Repo.get_by(Conversation, type: "channel", federated_source: channel_id)
      assert mirror_server
      assert mirror_channel

      assert_receive {:federation_presence_update, presence_broadcast}, 1_000
      assert Enum.sort(presence_broadcast.server_ids) == [mirror_server.id]
      assert presence_broadcast.status == "online"
      assert presence_broadcast.handle == "@modbot@remote.example"

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

      assert Repo.get_by(FederationAccountPresenceState,
               remote_actor_id: actor.id,
               status: "online"
             )

      assert Enum.any?(Federation.list_server_presence_states(mirror_server.id), fn state ->
               state.status == "online"
             end)

      assert Enum.any?(
               Federation.list_visible_server_presence_states(mirror_server.id, subscriber.id),
               fn state -> state.remote_actor_id == actor.id and state.status == "online" end
             )

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

    test "publishes shared-governance extension events with local projections and room fanout" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "shared-governance-local"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "local governance"
        })

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/alice",
          username: "alice",
          domain: "remote.example",
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      assert :ok =
               Federation.publish_extension_event(
                 channel.id,
                 owner.id,
                 "role.upsert",
                 %{
                   "role" => %{
                     "id" => "builtin:admin",
                     "name" => "Admin",
                     "permissions" => ["manage_roles", "manage_permissions"],
                     "position" => 80
                   }
                 }
               )

      canonical_event_type = ArblargSDK.canonical_event_type("role.upsert")

      assert Repo.get_by(FederationExtensionEvent,
               event_type: canonical_event_type,
               origin_domain: Federation.local_domain(),
               event_key: "role:builtin:admin:channel:#{channel.id}"
             )

      assert {:ok, _event, target_domains, ^canonical_event_type, extension_payload} =
               Builders.build_extension_event(
                 channel.id,
                 owner.id,
                 "role.upsert",
                 %{
                   "role" => %{
                     "id" => "builtin:admin",
                     "name" => "Admin",
                     "permissions" => ["manage_roles", "manage_permissions"],
                     "position" => 80
                   }
                 },
                 builder_context()
               )

      assert "remote.example" in target_domains

      assert get_in(extension_payload, ["actor", "handle"]) ==
               "#{owner.username}@#{Federation.local_domain()}"
    end

    test "applies room-scoped presence updates for shared-room participants without follows" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "room-presence-local"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "room presence"
        })

      remote_domain = "remote.example"
      actor_uri = "https://remote.example/users/alice"

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "alice",
          domain: remote_domain,
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: remote_domain,
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      Phoenix.PubSub.subscribe(
        Elektrine.PubSub,
        Elektrine.PubSubTopics.conversation(channel.id)
      )

      presence_update_item = %{
        "event_type" => "presence.update",
        "origin_domain" => remote_domain,
        "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "payload" => %{
          "refs" => %{
            "server_id" => Elektrine.Messaging.Federation.Utils.server_federation_id(server.id),
            "channel_id" => Elektrine.Messaging.Federation.Utils.channel_federation_id(channel.id)
          },
          "presence" => %{
            "actor" =>
              canonical_actor("alice", remote_domain,
                uri: actor_uri,
                display_name: "Alice"
              ),
            "status" => "online",
            "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "activities" => [%{"name" => "Reading ops"}]
          }
        }
      }

      assert {:ok, %{"counts" => %{"applied" => 1}}} =
               Federation.receive_ephemeral_batch(
                 %{"items" => [presence_update_item]},
                 remote_domain
               )

      assert_receive {:federation_presence_update, presence_broadcast}, 1_000
      assert presence_broadcast.conversation_id == channel.id
      assert presence_broadcast.remote_actor_id == remote_actor.id
      assert presence_broadcast.status == "online"

      assert Repo.get_by(FederationRoomPresenceState,
               conversation_id: channel.id,
               remote_actor_id: remote_actor.id,
               status: "online"
             )

      refute Repo.get_by(FederationAccountPresenceState, remote_actor_id: remote_actor.id)

      assert Enum.any?(
               Federation.list_visible_room_presence_states(channel.id, owner.id),
               fn state ->
                 state.remote_actor_id == remote_actor.id and state.status == "online"
               end
             )
    end

    test "ignores remote presence updates without a local subscription" do
      remote_domain = "remote.example"
      actor_uri = "https://remote.example/users/ghost"

      presence_update_item = %{
        "event_type" => "presence.update",
        "origin_domain" => remote_domain,
        "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "payload" => %{
          "presence" => %{
            "actor" =>
              canonical_actor("ghost", remote_domain,
                uri: actor_uri,
                display_name: "Ghost"
              ),
            "status" => "online",
            "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "activities" => [%{"name" => "Lurking"}]
          }
        }
      }

      assert {:ok, %{"counts" => %{"applied" => 1}}} =
               Federation.receive_ephemeral_batch(
                 %{"items" => [presence_update_item]},
                 remote_domain
               )

      refute_receive {:federation_presence_update, _payload}, 200

      actor = Repo.get_by(Actor, uri: actor_uri)
      assert actor

      refute Repo.get_by(FederationAccountPresenceState, remote_actor_id: actor.id)
    end
  end

  describe "outbound room participation" do
    test "builds room-scoped presence updates against participant homeservers" do
      user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()

      assert {:ok, item, target_domains} =
               Builders.build_room_presence_ephemeral_item(
                 channel.id,
                 user.id,
                 "online",
                 [%{"name" => "Browsing"}],
                 builder_context()
               )

      assert item["event_type"] == "presence.update"
      assert get_in(item, ["payload", "refs", "channel_id"]) == channel.federated_source
      assert get_in(item, ["payload", "presence", "status"]) == "online"
      assert "remote.example" in target_domains
    end

    test "builds message.create against the remote room stream for mirrored channels" do
      user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()
      message = mirrored_local_message_fixture(channel.id, user.id, "hello remote room")

      assert {:ok, event} = Builders.build_message_created_event(message, builder_context())
      assert event["event_type"] == "message.create"
      assert event["stream_id"] == "channel:#{channel.federated_source}"
      assert get_in(event, ["payload", "refs", "channel_id"]) == channel.federated_source
      assert get_in(event, ["payload", "message", "content"]) == "hello remote room"
    end

    test "targets all known participant homeservers for mirrored room events" do
      user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()
      message = mirrored_local_message_fixture(channel.id, user.id, "hello everyone")
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      for {username, domain} <- [{"alice", "remote-b.example"}, {"carol", "remote-c.example"}] do
        actor =
          %Actor{}
          |> Actor.changeset(%{
            uri: "https://#{domain}/users/#{username}",
            username: username,
            domain: domain,
            inbox_url: "https://#{domain}/users/#{username}/inbox",
            public_key: "test-public-key"
          })
          |> Repo.insert!()

        Repo.insert!(%FederationMembershipState{
          conversation_id: channel.id,
          remote_actor_id: actor.id,
          origin_domain: domain,
          role: "member",
          state: "active",
          joined_at_remote: timestamp,
          updated_at_remote: timestamp,
          metadata: %{}
        })
      end

      assert {:ok, event} = Builders.build_message_created_event(message, builder_context())

      assert Enum.sort(Visibility.target_domains_for_event(event)) == [
               "remote-b.example",
               "remote-c.example",
               "remote.example"
             ]
    end

    test "builds read.cursor against the remote room origin for mirrored channels" do
      user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()
      message = mirrored_local_message_fixture(channel.id, user.id, "read target")

      assert {:ok, event, target_domains} =
               Builders.build_read_cursor_event(
                 channel.id,
                 user.id,
                 message.id,
                 DateTime.utc_now(),
                 builder_context()
               )

      assert event["event_type"] == "read.cursor"
      assert event["stream_id"] == "channel:#{channel.federated_source}"
      assert target_domains == ["remote.example"]
    end

    test "builds membership.upsert against the remote room origin for mirrored channels" do
      user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()

      assert {:ok, _member} = Messaging.add_member_to_conversation(channel.id, user.id)

      assert {:ok, event, target_domains} =
               Builders.build_membership_upsert_event(
                 channel.id,
                 user.id,
                 "active",
                 "member",
                 builder_context()
               )

      assert event["event_type"] == "membership.upsert"
      assert event["stream_id"] == "channel:#{channel.federated_source}"
      assert target_domains == ["remote.example"]
      assert get_in(event, ["payload", "refs", "channel_id"]) == channel.federated_source
    end

    test "requests mirrored room joins without creating an immediate local membership" do
      user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()
      local_uri = "https://#{Federation.local_domain()}/users/#{user.username}"

      assert {:ok, :pending} = Messaging.join_conversation(channel.id, user.id)

      refute Repo.get_by(ConversationMember, conversation_id: channel.id, user_id: user.id)

      assert Repo.get_by(FederationInviteState,
               conversation_id: channel.id,
               target_uri: local_uri,
               state: "pending"
             )
    end
  end

  describe "authorized room egress" do
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
              shared_secret: "room-secret",
              allow_incoming: true,
              allow_outgoing: true,
              supported_event_types: ["message.create"]
            },
            %{
              domain: "remote-b.example",
              base_url: "https://remote-b.example",
              shared_secret: "remote-b-room-secret",
              allow_incoming: true,
              allow_outgoing: true,
              supported_event_types: ["message.create", "invite.upsert"]
            },
            %{
              domain: "stranger.example",
              base_url: "https://stranger.example",
              shared_secret: "stranger-secret",
              allow_incoming: true,
              allow_outgoing: true,
              supported_event_types: ["message.create"]
            }
          ]
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      :ok
    end

    test "routes room events only to authorized peers and hides replay from others" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "private-room", is_public: false})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "private room",
          is_public: false
        })

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/alice",
          username: "alice",
          domain: "remote.example",
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      message =
        %ChatMessage{}
        |> ChatMessage.changeset(%{
          conversation_id: channel.id,
          sender_id: owner.id,
          content: "classified",
          message_type: "text"
        })
        |> Repo.insert!()

      assert {:ok, event} = Builders.build_message_created_event(message, builder_context())
      assert Visibility.target_domains_for_event(event) == ["remote.example"]

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      outbox_event =
        Repo.insert!(%FederationOutboxEvent{
          event_id: event["event_id"],
          event_type: event["event_type"],
          stream_id: event["stream_id"],
          sequence: event["sequence"],
          payload: event,
          target_domains: ["remote.example"],
          delivered_domains: [],
          attempt_count: 0,
          max_attempts: 8,
          status: "pending",
          next_retry_at: now,
          partition_month: Date.new!(now.year, now.month, 1)
        })

      assert outbox_event.target_domains == ["remote.example"]

      visible_replay =
        Federation.export_stream_events(outbox_event.stream_id, peer: %{domain: "remote.example"})

      hidden_replay =
        Federation.export_stream_events(outbox_event.stream_id,
          peer: %{domain: "stranger.example"}
        )

      assert length(visible_replay["events"]) == 1
      assert hidden_replay["events"] == []
      assert hidden_replay["last_sequence"] == 0
    end

    test "replay exposes older room participation events to newly authorized peers without leaking targeted governance" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "history-room", is_public: false})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "private room",
          is_public: false
        })

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/alice",
          username: "alice",
          domain: "remote.example",
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      message =
        %ChatMessage{}
        |> ChatMessage.changeset(%{
          conversation_id: channel.id,
          sender_id: owner.id,
          content: "durable room history",
          message_type: "text"
        })
        |> Repo.insert!()

      assert {:ok, message_event} =
               Builders.build_message_created_event(message, builder_context())

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%FederationOutboxEvent{
        event_id: message_event["event_id"],
        event_type: message_event["event_type"],
        stream_id: message_event["stream_id"],
        sequence: message_event["sequence"],
        payload: message_event,
        target_domains: ["remote.example"],
        delivered_domains: [],
        attempt_count: 0,
        max_attempts: 8,
        status: "pending",
        next_retry_at: now,
        partition_month: Date.new!(now.year, now.month, 1)
      })

      invite_event =
        Builders.event_envelope(
          "invite.upsert",
          message_event["stream_id"],
          message_event["sequence"] + 1,
          %{
            "refs" => %{
              "server_id" =>
                server.federation_id ||
                  Elektrine.Messaging.Federation.Utils.server_federation_id(server.id),
              "channel_id" =>
                channel.federated_source ||
                  Elektrine.Messaging.Federation.Utils.channel_federation_id(channel.id)
            },
            "invite" => %{
              "actor" => canonical_actor(owner.username, Federation.local_domain()),
              "target" => canonical_actor("bob", "remote.example"),
              "role" => "member",
              "state" => "pending",
              "invited_at" => DateTime.to_iso8601(now),
              "updated_at" => DateTime.to_iso8601(now),
              "metadata" => %{}
            }
          },
          builder_context()
        )

      Repo.insert!(%FederationOutboxEvent{
        event_id: invite_event["event_id"],
        event_type: invite_event["event_type"],
        stream_id: invite_event["stream_id"],
        sequence: invite_event["sequence"],
        payload: invite_event,
        target_domains: ["remote.example"],
        delivered_domains: [],
        attempt_count: 0,
        max_attempts: 8,
        status: "pending",
        next_retry_at: now,
        partition_month: Date.new!(now.year, now.month, 1)
      })

      newly_authorized_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote-b.example/users/carol",
          username: "carol",
          domain: "remote-b.example",
          inbox_url: "https://remote-b.example/users/carol/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      Repo.insert!(%FederationMembershipState{
        conversation_id: channel.id,
        remote_actor_id: newly_authorized_actor.id,
        origin_domain: "remote-b.example",
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      replay =
        Federation.export_stream_events(message_event["stream_id"],
          peer: %{domain: "remote-b.example"}
        )

      assert Enum.any?(replay["events"], &(&1["event_id"] == message_event["event_id"]))
      refute Enum.any?(replay["events"], &(&1["event_id"] == invite_event["event_id"]))
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
      dm_event_type = Elektrine.Messaging.ArblargSDK.dm_message_create_event_type()
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
          Elektrine.Messaging.ArblargSDK.dm_message_create_event_type(),
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
  end

  describe "remote join moderation workflow" do
    test "lists and approves pending remote join requests for a local authoritative room" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "approval-hub"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "gated-room",
          description: "requires approval"
        })

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/alice",
          username: "alice",
          domain: "remote.example",
          display_name: "Alice",
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      %FederationMembershipState{}
      |> FederationMembershipState.changeset(%{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "invited",
        updated_at_remote: inserted_at,
        metadata: %{"join_request" => true, "reason" => "approval_required"}
      })
      |> Repo.insert!()

      assert [
               %{
                 remote_actor_id: remote_actor_id,
                 handle: "@alice@remote.example",
                 display_label: "Alice (@alice@remote.example)"
               }
             ] = Messaging.list_pending_remote_join_requests(channel.id)

      assert remote_actor_id == remote_actor.id

      assert {:ok, approved_request} =
               Messaging.approve_remote_join_request(channel.id, remote_actor.id, owner.id)

      assert approved_request.state == "active"

      assert %FederationMembershipState{} =
               membership_state =
               Repo.get_by(FederationMembershipState,
                 conversation_id: channel.id,
                 remote_actor_id: remote_actor.id
               )

      assert membership_state.state == "active"
      assert get_in(membership_state.metadata, ["join_request"]) == false
      assert get_in(membership_state.metadata, ["join_decision"]) == "accepted"
      assert Messaging.list_pending_remote_join_requests(channel.id) == []
    end

    test "declines pending remote join requests and removes them from the pending queue" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "approval-hub-decline"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "gated-room-decline",
          description: "requires approval"
        })

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/bob",
          username: "bob",
          domain: "remote.example",
          display_name: "Bob",
          inbox_url: "https://remote.example/users/bob/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      %FederationMembershipState{}
      |> FederationMembershipState.changeset(%{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "invited",
        updated_at_remote: inserted_at,
        metadata: %{"join_request" => true, "reason" => "approval_required"}
      })
      |> Repo.insert!()

      assert {:ok, declined_request} =
               Messaging.decline_remote_join_request(channel.id, remote_actor.id, owner.id)

      assert declined_request.state == "left"

      assert %FederationMembershipState{} =
               membership_state =
               Repo.get_by(FederationMembershipState,
                 conversation_id: channel.id,
                 remote_actor_id: remote_actor.id
               )

      assert membership_state.state == "left"
      assert get_in(membership_state.metadata, ["join_request"]) == false
      assert get_in(membership_state.metadata, ["join_decision"]) == "declined"
      assert Messaging.list_pending_remote_join_requests(channel.id) == []
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
          session_websocket: "ws://open.example/_arblarg/session"
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

    test "merges extension support advertised only through the profiles document" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])
      role_event_type = hd(ArblargSDK.roles_event_types())

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.profiles-only.example", "profiles-only.example" ->
              [
                authenticated_dns_identity_proof(
                  dynamic_discovery_document("profiles-only.example", "profiles-only-secret")
                )
              ]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "profiles-only.example", _urls ->
              {:ok, dynamic_discovery_document("profiles-only.example", "profiles-only-secret")}

            _domain, _urls ->
              {:error, :not_found}
          end,
          profiles_fetcher: fn
            "profiles-only.example", _url ->
              {:ok, dynamic_profiles_document(role_event_type)}

            _domain, _url ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:ok, peer} = Federation.discover_peer("profiles-only.example")
      assert Transport.peer_supports_event_type?(peer, role_event_type)

      assert ArblargProfiles.community_profile_id() in get_in(peer.features, [
               "compatibility_claims"
             ])
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

  describe "extension negotiation" do
    setup do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [
            %{
              domain: "bootstrap.example",
              base_url: "https://bootstrap.example",
              shared_secret: "bootstrap-secret",
              allow_incoming: true,
              allow_outgoing: true,
              supported_event_types: ["server.upsert"]
            },
            %{
              domain: "core-only.example",
              base_url: "https://core-only.example",
              shared_secret: "core-only-secret",
              allow_incoming: true,
              allow_outgoing: true,
              supported_event_types: ArblargSDK.core_event_types()
            }
          ]
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      :ok
    end

    test "filters bootstrap extension fanout to peers that advertise support" do
      bootstrap_event_type = ArblargSDK.bootstrap_server_upsert_event_type()

      bootstrap_peer = %{
        domain: "bootstrap.example",
        supported_event_types: [bootstrap_event_type],
        features: %{"supported_event_types" => [bootstrap_event_type]}
      }

      core_only_peer = %{
        domain: "core-only.example",
        supported_event_types: ArblargSDK.core_event_types(),
        features: %{"supported_event_types" => ArblargSDK.core_event_types()}
      }

      assert Transport.peer_supports_event_type?(bootstrap_peer, bootstrap_event_type)
      refute Transport.peer_supports_event_type?(core_only_peer, bootstrap_event_type)
    end

    test "accepts community profile claims as extension support" do
      peer = %{
        features: %{
          "compatibility_claims" => [ArblargProfiles.community_profile_id()]
        }
      }

      assert Transport.peer_supports_event_type?(peer, hd(ArblargSDK.roles_event_types()))
      refute Transport.peer_supports_event_type?(%{}, hd(ArblargSDK.roles_event_types()))
    end
  end

  defp dynamic_discovery_document(domain, secret, opts \\ []) do
    {public_key, _private_key} = ArblargSDK.derive_keypair_from_secret(secret)
    base_url = "https://#{domain}"
    claimed_domain = Keyword.get(opts, :claimed_domain, domain)

    default_protocol_version =
      Keyword.get(opts, :default_protocol_version, ArblargSDK.protocol_version())

    session_websocket =
      Keyword.get(opts, :session_websocket, "wss://#{domain}/_arblarg/session")

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
          "well_known" => "#{base_url}/.well-known/_arblarg",
          "events" => "#{base_url}/_arblarg/events",
          "events_batch" => "#{base_url}/_arblarg/events/batch",
          "ephemeral" => "#{base_url}/_arblarg/ephemeral",
          "sync" => "#{base_url}/_arblarg/sync",
          "stream_events" => "#{base_url}/_arblarg/streams/events",
          "session_websocket" => session_websocket,
          "snapshot_template" => "#{base_url}/_arblarg/servers/{server_id}/snapshot",
          "public_servers" => "#{base_url}/_arblarg/servers/public",
          "profiles" => "#{base_url}/_arblarg/profiles",
          "schema_template" => "#{base_url}/_arblarg/{version}/schemas/{name}"
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

  defp dynamic_profiles_document(event_type) when is_binary(event_type) do
    %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "default_protocol_version" => ArblargSDK.protocol_version(),
      "version" => 1,
      "compatibility_claims" => [ArblargProfiles.community_profile_id()],
      "events" => %{"supported" => [event_type]},
      "extensions" => [
        %{
          "urn" => ArblargProfiles.extension_urn_for_event_type(event_type)
        }
      ]
    }
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

  defp mirrored_channel_fixture do
    suffix = System.unique_integer([:positive])

    server =
      %Server{}
      |> Server.changeset(%{
        name: "Remote Server #{suffix}",
        description: "Federated mirror server",
        federation_id: "https://remote.example/_arblarg/servers/#{suffix}",
        origin_domain: "remote.example",
        is_federated_mirror: true
      })
      |> Repo.insert!()

    %ChatConversation{}
    |> ChatConversation.channel_changeset(%{
      name: "remote-channel-#{suffix}",
      description: "Mirrored remote channel",
      server_id: server.id,
      federated_source: "https://remote.example/_arblarg/channels/#{suffix}",
      is_federated_mirror: true
    })
    |> Repo.insert!()
  end

  defp mirrored_local_message_fixture(conversation_id, sender_id, content) do
    %ChatMessage{}
    |> ChatMessage.changeset(%{
      conversation_id: conversation_id,
      sender_id: sender_id,
      content: content,
      message_type: "text"
    })
    |> Repo.insert!()
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

  defp default_snapshot_stream_positions(%{
         "origin_domain" => origin_domain,
         "server" => %{"id" => server_id}
       })
       when is_binary(origin_domain) and is_binary(server_id) do
    [
      %{
        "origin_domain" => origin_domain,
        "stream_id" => "server:#{server_id}",
        "last_sequence" => 0
      }
    ]
  end

  defp default_snapshot_stream_positions(_payload), do: []
end
