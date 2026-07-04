defmodule Elektrine.Messaging.FederationPinsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging

  alias Elektrine.Messaging.{
    ArblargSDK,
    ChatConversation,
    ChatMessage,
    ChatMessagePin,
    ChatMessagePins,
    FederationExtensionEvent,
    FederationMembershipState,
    Server
  }

  alias Elektrine.Messaging.Federation.EventRouter
  alias Elektrine.Repo

  @remote_domain "remote.example"

  describe "outbound pin federation" do
    test "pinning a channel message publishes a schema-valid pin.upsert projection" do
      %{owner: owner, member: member, channel: channel} = local_channel_with_member()

      {:ok, message} = Messaging.create_chat_text_message(channel.id, member.id, "pin me")
      assert {:ok, _pinned} = ChatMessagePins.pin_message(message.id, owner.id)

      canonical_type = ArblargSDK.canonical_event_type("pin.upsert")
      message_ref = message_federation_ref(message)

      assert %FederationExtensionEvent{payload: payload, status: "pinned"} =
               Repo.get_by(FederationExtensionEvent,
                 event_type: canonical_type,
                 conversation_id: channel.id,
                 event_key: "pin:#{message_ref}:channel:#{channel.id}"
               )

      assert get_in(payload, ["pin", "message_id"]) == message_ref
      assert get_in(payload, ["pin", "state"]) == "pinned"
      assert get_in(payload, ["actor", "username"]) == owner.username
      assert :ok = ArblargSDK.validate_event_payload(canonical_type, payload)
    end

    test "unpinning updates the projection to unpinned" do
      %{owner: owner, member: member, channel: channel} = local_channel_with_member()

      {:ok, message} = Messaging.create_chat_text_message(channel.id, member.id, "short pin")
      {:ok, _} = ChatMessagePins.pin_message(message.id, owner.id)
      assert {:ok, _} = ChatMessagePins.unpin_message(message.id, owner.id)

      canonical_type = ArblargSDK.canonical_event_type("pin.upsert")
      message_ref = message_federation_ref(message)

      assert %FederationExtensionEvent{payload: payload, status: "unpinned"} =
               Repo.get_by(FederationExtensionEvent,
                 event_type: canonical_type,
                 conversation_id: channel.id,
                 event_key: "pin:#{message_ref}:channel:#{channel.id}"
               )

      assert get_in(payload, ["pin", "state"]) == "unpinned"
      assert :ok = ArblargSDK.validate_event_payload(canonical_type, payload)
    end

    test "pins in groups stay local" do
      creator = AccountsFixtures.user_fixture()
      buddy = AccountsFixtures.user_fixture()

      {:ok, group} =
        Messaging.create_chat_group_conversation(creator.id, %{name: "local pins"}, [buddy.id])

      {:ok, message} = Messaging.create_chat_text_message(group.id, buddy.id, "group pin")
      assert {:ok, _} = ChatMessagePins.pin_message(message.id, creator.id)

      refute Repo.get_by(FederationExtensionEvent,
               event_type: ArblargSDK.canonical_event_type("pin.upsert"),
               conversation_id: group.id
             )
    end
  end

  describe "inbound pin federation" do
    test "pin.upsert pins the mirrored message and unpin removes it" do
      %{channel: channel} = mirrored_channel_fixture()
      moderator = remote_member_fixture(channel, "mod", "moderator")

      message_ref = "https://#{@remote_domain}/_arblarg/messages/6100"
      mirror_message = mirror_message_fixture(channel, message_ref, "remote pinned content")

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{channel.id}")

      pinned_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert :ok =
               EventRouter.apply_event(
                 "pin.upsert",
                 pin_upsert_data(channel, moderator, message_ref, "pinned", pinned_at),
                 @remote_domain
               )

      assert %ChatMessagePin{pinned_by_id: nil} =
               Repo.get_by(ChatMessagePin,
                 conversation_id: channel.id,
                 message_id: mirror_message.id
               )

      message_id = mirror_message.id
      assert_receive {:message_pinned, %ChatMessage{id: ^message_id, is_pinned: true}}

      assert Enum.map(ChatMessagePins.list_pinned_messages(channel.id), & &1.id) == [
               mirror_message.id
             ]

      unpinned_at = DateTime.add(pinned_at, 5, :second)

      assert :ok =
               EventRouter.apply_event(
                 "pin.upsert",
                 pin_upsert_data(channel, moderator, message_ref, "unpinned", unpinned_at),
                 @remote_domain
               )

      refute Repo.get_by(ChatMessagePin, message_id: mirror_message.id)
      assert_receive {:message_unpinned, %ChatMessage{id: ^message_id, is_pinned: false}}
    end

    test "pin.upsert from a plain member without manage_messages is rejected" do
      %{channel: channel} = mirrored_channel_fixture()
      member = remote_member_fixture(channel, "alice", "member")

      message_ref = "https://#{@remote_domain}/_arblarg/messages/6101"
      mirror_message = mirror_message_fixture(channel, message_ref, "not pinnable by member")

      assert {:error, _reason} =
               EventRouter.apply_event(
                 "pin.upsert",
                 pin_upsert_data(channel, member, message_ref, "pinned", DateTime.utc_now()),
                 @remote_domain
               )

      refute Repo.get_by(ChatMessagePin, message_id: mirror_message.id)
    end

    test "pin.upsert for an unknown message stores the projection without a local pin" do
      %{channel: channel} = mirrored_channel_fixture()
      moderator = remote_member_fixture(channel, "mod", "moderator")

      message_ref = "https://#{@remote_domain}/_arblarg/messages/does-not-exist"

      assert :ok =
               EventRouter.apply_event(
                 "pin.upsert",
                 pin_upsert_data(channel, moderator, message_ref, "pinned", DateTime.utc_now()),
                 @remote_domain
               )

      assert Repo.get_by(FederationExtensionEvent,
               event_type: ArblargSDK.canonical_event_type("pin.upsert"),
               event_key: "pin:#{message_ref}:channel:#{channel.id}"
             )

      assert Repo.aggregate(
               from(pin in ChatMessagePin, where: pin.conversation_id == ^channel.id),
               :count
             ) == 0
    end
  end

  ## Fixtures

  defp local_channel_with_member do
    owner = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()

    {:ok, server} = Messaging.create_server(owner.id, %{name: "pin-fed", is_public: true})
    {:ok, _member} = Messaging.join_server(server.id, member.id)
    [channel | _] = server.channels

    %{owner: owner, member: member, server: server, channel: channel}
  end

  defp mirrored_channel_fixture do
    suffix = System.unique_integer([:positive])

    server =
      %Server{}
      |> Server.changeset(%{
        name: "Remote Server #{suffix}",
        description: "Federated mirror server",
        federation_id: "https://#{@remote_domain}/_arblarg/servers/#{suffix}",
        origin_domain: @remote_domain,
        is_federated_mirror: true
      })
      |> Repo.insert!()

    channel =
      %ChatConversation{}
      |> ChatConversation.channel_changeset(%{
        name: "remote-channel-#{suffix}",
        description: "Mirrored remote channel",
        server_id: server.id,
        federated_source: "https://#{@remote_domain}/_arblarg/channels/#{suffix}",
        is_federated_mirror: true
      })
      |> Repo.insert!()

    %{server: server, channel: channel}
  end

  defp mirror_message_fixture(channel, federation_ref, content) do
    %ChatMessage{}
    |> ChatMessage.changeset(%{
      conversation_id: channel.id,
      sender_id: nil,
      content: content,
      message_type: "text",
      federated_source: federation_ref,
      origin_domain: @remote_domain,
      is_federated_mirror: true,
      media_metadata: %{"remote_sender" => canonical_actor("someone")}
    })
    |> Repo.insert!()
  end

  defp remote_member_fixture(channel, username, role) do
    actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://#{@remote_domain}/users/#{username}",
        username: username,
        domain: @remote_domain,
        inbox_url: "https://#{@remote_domain}/users/#{username}/inbox",
        public_key: "test-public-key"
      })
      |> Repo.insert!()

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%FederationMembershipState{
      conversation_id: channel.id,
      remote_actor_id: actor.id,
      origin_domain: @remote_domain,
      role: role,
      state: "active",
      joined_at_remote: timestamp,
      updated_at_remote: timestamp,
      metadata: %{}
    })

    actor
  end

  defp pin_upsert_data(channel, %Actor{} = actor, message_ref, state, updated_at) do
    server = Repo.get!(Server, channel.server_id)

    %{
      "server" => %{"id" => server.federation_id, "name" => server.name, "is_public" => true},
      "channel" => %{
        "id" => channel.federated_source,
        "name" => channel.name,
        "position" => 0
      },
      "refs" => %{
        "server_id" => server.federation_id,
        "channel_id" => channel.federated_source
      },
      "pin" => %{
        "message_id" => message_ref,
        "state" => state,
        "updated_at" => DateTime.to_iso8601(updated_at)
      },
      "actor" => canonical_actor(actor.username, uri: actor.uri)
    }
  end

  defp canonical_actor(username, opts \\ []) do
    uri = Keyword.get(opts, :uri, "https://#{@remote_domain}/users/#{username}")

    %{
      "id" => uri,
      "uri" => uri,
      "username" => username,
      "display_name" => username,
      "domain" => @remote_domain,
      "handle" => "#{username}@#{@remote_domain}"
    }
  end

  defp message_federation_ref(message) do
    message.federated_source ||
      Elektrine.Messaging.Federation.Utils.message_federation_id(message.id)
  end
end
