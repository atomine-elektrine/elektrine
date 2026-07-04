defmodule Elektrine.Messaging.FederationThreadsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging

  alias Elektrine.Messaging.{
    ArblargSDK,
    ChatConversation,
    ChatThread,
    ChatThreads,
    FederationExtensionEvent,
    FederationMembershipState,
    Server
  }

  alias Elektrine.Messaging.Federation.{Builders, EventRouter}
  alias Elektrine.Repo

  @remote_domain "remote.example"

  describe "outbound thread federation" do
    test "create_thread publishes a schema-valid thread.upsert extension event" do
      %{owner: owner, channel: channel} = local_server_channel_fixture()

      assert {:ok, thread} =
               ChatThreads.create_thread(channel.id, owner.id, %{title: "Federated plans"})

      # The publish path validates against the SDK schema before persisting the
      # local extension projection, so this row proves a valid payload.
      canonical_type = ArblargSDK.canonical_event_type("thread.upsert")
      thread_ref = ChatThreads.thread_federation_ref(thread)

      assert %FederationExtensionEvent{payload: payload, status: "active"} =
               Repo.get_by(FederationExtensionEvent,
                 event_type: canonical_type,
                 conversation_id: channel.id,
                 event_key: "thread:#{thread_ref}:channel:#{channel.id}"
               )

      assert get_in(payload, ["thread", "name"]) == "Federated plans"
      assert get_in(payload, ["thread", "state"]) == "active"
      assert get_in(payload, ["thread", "owner", "username"]) == owner.username
      assert :ok = ArblargSDK.validate_event_payload(canonical_type, payload)
    end

    test "archive_thread publishes a schema-valid thread.archive extension event" do
      %{owner: owner, channel: channel} = local_server_channel_fixture()

      {:ok, thread} = ChatThreads.create_thread(channel.id, owner.id, %{title: "Short lived"})
      assert {:ok, _archived} = ChatThreads.archive_thread(thread.id, owner.id)

      canonical_type = ArblargSDK.canonical_event_type("thread.archive")
      thread_ref = ChatThreads.thread_federation_ref(thread)

      assert %FederationExtensionEvent{payload: payload} =
               Repo.get_by(FederationExtensionEvent,
                 event_type: canonical_type,
                 conversation_id: channel.id,
                 event_key: "thread:#{thread_ref}:channel:#{channel.id}"
               )

      assert payload["thread_id"] == thread_ref
      assert is_binary(payload["archived_at"])
      assert get_in(payload, ["actor", "username"]) == owner.username
      assert :ok = ArblargSDK.validate_event_payload(canonical_type, payload)
    end

    test "builds a signed thread.upsert envelope through the extension event builder" do
      %{owner: owner, channel: channel} = local_server_channel_fixture()

      {:ok, thread} = ChatThreads.create_thread(channel.id, owner.id, %{title: "Envelope"})
      payload = ChatThreads.thread_upsert_payload(thread, Repo.get(ChatConversation, channel.id))

      assert {:ok, event, _target_domains, canonical_type, extension_payload} =
               Builders.build_extension_event(
                 channel.id,
                 owner.id,
                 "thread.upsert",
                 payload,
                 builder_context()
               )

      assert canonical_type == ArblargSDK.canonical_event_type("thread.upsert")
      assert event["event_type"] == canonical_type
      assert :ok = ArblargSDK.validate_event_payload(canonical_type, extension_payload)
      assert :ok = ArblargSDK.validate_event_envelope(event)
    end
  end

  describe "thread message federation" do
    test "outbound thread messages carry a schema-valid thread_id reference" do
      %{owner: owner, channel: channel} = local_server_channel_fixture()

      {:ok, thread} = ChatThreads.create_thread(channel.id, owner.id, %{title: "Ref carrier"})
      {:ok, message} = ChatThreads.create_thread_message(thread.id, owner.id, "reply in thread")

      assert {:ok, event} =
               Builders.build_message_created_event(message, builder_context())

      assert event["event_type"] == "message.create"

      assert get_in(event, ["payload", "message", "thread_id"]) ==
               ChatThreads.thread_federation_ref(thread)

      assert :ok = ArblargSDK.validate_event_envelope(event)
      assert :ok = ArblargSDK.validate_event_payload("message.create", event["payload"])
    end

    test "outbound main-timeline messages carry no thread_id" do
      %{owner: owner, channel: channel} = local_server_channel_fixture()

      {:ok, message} = Messaging.create_chat_text_message(channel.id, owner.id, "plain message")

      assert {:ok, event} =
               Builders.build_message_created_event(message, builder_context())

      refute Map.has_key?(event["payload"]["message"], "thread_id")
    end

    test "inbound message.create with a known thread ref lands in the thread" do
      %{channel: channel} = mirrored_channel_fixture()
      actor = remote_member_fixture(channel, "alice", "member")

      thread_ref = "https://#{@remote_domain}/_arblarg/threads/9100"

      assert :ok =
               EventRouter.apply_event(
                 "thread.upsert",
                 thread_upsert_data(channel, thread_ref, "Inbound thread", "active", actor),
                 @remote_domain
               )

      thread = Repo.get_by(ChatThread, federation_id: thread_ref, origin_domain: @remote_domain)

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{channel.id}")

      assert :ok =
               EventRouter.apply_event(
                 "message.create",
                 message_create_data(
                   channel,
                   actor,
                   "https://#{@remote_domain}/_arblarg/messages/8100",
                   content: "remote reply",
                   thread_id: thread_ref
                 ),
                 @remote_domain
               )

      message =
        Repo.get_by(Elektrine.Messaging.ChatMessage,
          conversation_id: channel.id,
          federated_source: "https://#{@remote_domain}/_arblarg/messages/8100"
        )

      assert message.thread_id == thread.id

      # Counters bump on top of the remote-declared message_count (3).
      updated = ChatThreads.get_thread(thread.id)
      assert updated.message_count == 4

      # Thread messages broadcast into the thread panel, not the timeline.
      message_id = message.id
      assert_receive {:new_thread_message, %Elektrine.Messaging.ChatMessage{id: ^message_id}}

      assert message.id in Enum.map(ChatThreads.list_thread_messages(thread.id), & &1.id)
    end

    test "inbound message.create with an unknown thread ref falls back to the timeline" do
      %{channel: channel} = mirrored_channel_fixture()
      actor = remote_member_fixture(channel, "alice", "member")

      assert :ok =
               EventRouter.apply_event(
                 "message.create",
                 message_create_data(
                   channel,
                   actor,
                   "https://#{@remote_domain}/_arblarg/messages/8101",
                   content: "orphan thread ref",
                   thread_id: "https://#{@remote_domain}/_arblarg/threads/does-not-exist"
                 ),
                 @remote_domain
               )

      message =
        Repo.get_by(Elektrine.Messaging.ChatMessage,
          conversation_id: channel.id,
          federated_source: "https://#{@remote_domain}/_arblarg/messages/8101"
        )

      assert is_nil(message.thread_id)
    end
  end

  describe "inbound thread federation" do
    test "thread.upsert creates a local chat_threads row on a mirrored channel" do
      %{channel: channel} = mirrored_channel_fixture()
      actor = remote_member_fixture(channel, "alice", "member")

      thread_id = "https://#{@remote_domain}/_arblarg/threads/9001"

      assert :ok =
               EventRouter.apply_event(
                 "thread.upsert",
                 thread_upsert_data(channel, thread_id, "Remote planning", "active", actor),
                 @remote_domain
               )

      assert %ChatThread{} =
               thread =
               Repo.get_by(ChatThread,
                 federation_id: thread_id,
                 origin_domain: @remote_domain
               )

      assert thread.conversation_id == channel.id
      assert thread.title == "Remote planning"
      assert thread.message_count == 3
      assert is_nil(thread.archived_at)

      # The extension event projection is stored alongside the local row.
      assert Repo.get_by(FederationExtensionEvent,
               event_type: ArblargSDK.canonical_event_type("thread.upsert"),
               event_key: "thread:#{thread_id}:channel:#{channel.id}"
             )
    end

    test "a later thread.upsert updates the projected local thread" do
      %{channel: channel} = mirrored_channel_fixture()
      actor = remote_member_fixture(channel, "alice", "member")

      thread_id = "https://#{@remote_domain}/_arblarg/threads/9002"

      assert :ok =
               EventRouter.apply_event(
                 "thread.upsert",
                 thread_upsert_data(channel, thread_id, "First title", "active", actor),
                 @remote_domain
               )

      assert :ok =
               EventRouter.apply_event(
                 "thread.upsert",
                 thread_upsert_data(channel, thread_id, "Renamed thread", "active", actor),
                 @remote_domain
               )

      thread = Repo.get_by(ChatThread, federation_id: thread_id, origin_domain: @remote_domain)
      assert thread.title == "Renamed thread"

      assert Repo.aggregate(
               from(t in ChatThread, where: t.conversation_id == ^channel.id),
               :count
             ) == 1
    end

    test "thread.archive archives the projected local thread" do
      %{channel: channel} = mirrored_channel_fixture()
      actor = remote_member_fixture(channel, "alice", "moderator")

      thread_id = "https://#{@remote_domain}/_arblarg/threads/9003"

      assert :ok =
               EventRouter.apply_event(
                 "thread.upsert",
                 thread_upsert_data(channel, thread_id, "To be archived", "active", actor),
                 @remote_domain
               )

      archived_at = DateTime.utc_now() |> DateTime.truncate(:second)

      data =
        channel_refs(channel)
        |> Map.merge(%{
          "thread_id" => thread_id,
          "archived_at" => DateTime.to_iso8601(archived_at),
          "actor" => canonical_actor("alice")
        })

      assert :ok = EventRouter.apply_event("thread.archive", data, @remote_domain)

      thread = Repo.get_by(ChatThread, federation_id: thread_id, origin_domain: @remote_domain)
      assert thread.archived_at == archived_at
    end

    test "thread.upsert from a non-member is rejected and projects nothing" do
      %{channel: channel} = mirrored_channel_fixture()

      outsider =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://#{@remote_domain}/users/outsider",
          username: "outsider",
          domain: @remote_domain,
          inbox_url: "https://#{@remote_domain}/users/outsider/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      thread_id = "https://#{@remote_domain}/_arblarg/threads/9004"

      assert {:error, _reason} =
               EventRouter.apply_event(
                 "thread.upsert",
                 thread_upsert_data(channel, thread_id, "Denied", "active", outsider),
                 @remote_domain
               )

      refute Repo.get_by(ChatThread, federation_id: thread_id, origin_domain: @remote_domain)
    end
  end

  ## Fixtures and helpers

  defp local_server_channel_fixture do
    owner = AccountsFixtures.user_fixture()
    {:ok, server} = Messaging.create_server(owner.id, %{name: "thread-fed", is_public: true})
    [channel | _] = server.channels

    %{owner: owner, server: server, channel: channel}
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

  defp channel_refs(channel) do
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
      }
    }
  end

  defp thread_upsert_data(channel, thread_id, name, state, %Actor{} = owner_actor) do
    channel_refs(channel)
    |> Map.put("thread", %{
      "id" => thread_id,
      "channel_id" => channel.federated_source,
      "name" => name,
      "state" => state,
      "message_count" => 3,
      "owner" => canonical_actor(owner_actor.username, uri: owner_actor.uri)
    })
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

  defp message_create_data(channel, %Actor{} = sender, message_id, opts) do
    message =
      %{
        "id" => message_id,
        "channel_id" => channel.federated_source,
        "content" => Keyword.fetch!(opts, :content),
        "message_type" => "text",
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "sender" => canonical_actor(sender.username, uri: sender.uri)
      }
      |> maybe_put("thread_id", Keyword.get(opts, :thread_id))

    Map.put(channel_refs(channel), "message", message)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp builder_context do
    %{
      local_domain: &Elektrine.Messaging.Federation.Runtime.local_domain/0,
      local_event_signing_material:
        &Elektrine.Messaging.Federation.Runtime.local_event_signing_material/0,
      outgoing_peers: &Elektrine.Messaging.Federation.outgoing_peers/0,
      maybe_iso8601: fn
        %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
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
      end
    }
  end
end
