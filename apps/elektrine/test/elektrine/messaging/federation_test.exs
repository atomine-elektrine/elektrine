defmodule Elektrine.Messaging.FederationTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.{ChatMessage, Conversation, Federation, Server}
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
  end
end
