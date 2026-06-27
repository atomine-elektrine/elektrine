defmodule Elektrine.Messaging.FederationRoomParticipationTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging

  alias Elektrine.Messaging.{
    ChatConversation,
    ChatMessage,
    Federation,
    Federation.Visibility,
    FederationInviteState,
    FederationMembershipState,
    Server
  }

  alias Elektrine.Messaging.ChatConversationMember, as: ConversationMember
  alias Elektrine.Messaging.Federation.Builders
  alias Elektrine.Repo

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
end
