defmodule ElektrineWeb.MessagingFederationControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.FederationDiscoveredPeer
  alias Elektrine.Messaging.FederationExtensionEvent
  alias Elektrine.Messaging.FederationOutboxEvent
  alias Elektrine.Messaging.FederationRoomPresenceState
  alias Elektrine.Messaging.Server
  alias Elektrine.PubSubTopics
  alias Elektrine.Repo

  setup do
    previous = Application.get_env(:elektrine, :messaging_federation)

    Application.put_env(
      :elektrine,
      :messaging_federation,
      enabled: true,
      identity_key_id: "k1",
      conformance_core_passed: true,
      official_relay_operator: "Relay Collective",
      official_relays: [
        %{
          "name" => "Relay US",
          "url" => "https://relay-us.example.com"
        }
      ],
      peers: [
        %{
          "domain" => "remote.test",
          "base_url" => "https://remote.test",
          "shared_secret" => "test-shared-secret",
          "supported_event_types" => ArblargSDK.supported_event_types(),
          "active_outbound_key_id" => "k1",
          "keys" => [
            %{"id" => "k1", "secret" => "test-shared-secret", "active_outbound" => true},
            %{"id" => "k0", "secret" => "old-shared-secret"}
          ],
          "allow_incoming" => true,
          "allow_outgoing" => true
        }
      ]
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :messaging_federation, previous)
    end)

    :ok
  end

  describe "POST /_arblarg/sync" do
    test "accepts valid signed snapshot", %{conn: conn} do
      payload =
        %{
          "version" => 1,
          "origin_domain" => "remote.test",
          "server" => %{
            "id" => "https://remote.test/_arblarg/servers/7",
            "name" => "remote-seven",
            "description" => "Remote test server",
            "is_public" => true,
            "member_count" => 3
          },
          "channels" => [
            %{
              "id" => "https://remote.test/_arblarg/channels/9",
              "name" => "general",
              "position" => 0
            }
          ],
          "messages" => []
        }
        |> sign_snapshot("k1", "test-shared-secret")

      body = Jason.encode!(payload)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/sync", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/sync", body)

      response = json_response(conn, 200)
      assert response["status"] == "ok"
      assert is_integer(response["mirror_server_id"])
    end

    test "rejects invalid signature", %{conn: conn} do
      payload = %{
        "version" => 1,
        "origin_domain" => "remote.test",
        "server" => %{
          "id" => "https://remote.test/_arblarg/servers/7",
          "name" => "remote-seven"
        },
        "channels" => [],
        "messages" => []
      }

      conn =
        conn
        |> put_req_header("x-arblarg-domain", "remote.test")
        |> put_req_header(
          "x-arblarg-timestamp",
          Integer.to_string(System.system_time(:second))
        )
        |> put_req_header("x-arblarg-signature", "invalid")
        |> post("/_arblarg/sync", payload)

      _response = json_response(conn, 401)
    end

    test "accepts rotated key signatures by key id", %{conn: conn} do
      payload =
        %{
          "version" => 1,
          "origin_domain" => "remote.test",
          "server" => %{
            "id" => "https://remote.test/_arblarg/servers/88",
            "name" => "rotated-key-server"
          },
          "channels" => [],
          "messages" => []
        }
        |> sign_snapshot("k0", "old-shared-secret")

      body = Jason.encode!(payload)

      conn =
        conn
        |> signed_federation_headers(
          "POST",
          "/_arblarg/sync",
          raw_body: body,
          key_id: "k0",
          secret: "old-shared-secret"
        )
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/sync", body)

      response = json_response(conn, 200)
      assert response["status"] == "ok"
    end

    test "bootstraps unknown peers through discovery metadata", %{conn: conn} do
      current = Application.get_env(:elektrine, :messaging_federation)

      Application.put_env(
        :elektrine,
        :messaging_federation,
        current
        |> Keyword.put(:peers, [])
        |> Keyword.put(:dns_identity_fetcher, fn
          "_arblarg.dynamic.test", "dynamic.test" ->
            [
              authenticated_dns_identity_proof(
                dynamic_discovery_document("dynamic.test", "dynamic-test-secret")
              )
            ]

          _name, _domain ->
            []
        end)
        |> Keyword.put(:discovery_fetcher, fn
          "dynamic.test", _urls ->
            {:ok, dynamic_discovery_document("dynamic.test", "dynamic-test-secret")}

          _domain, _urls ->
            {:error, :not_found}
        end)
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, current)
      end)

      payload =
        %{
          "version" => 1,
          "origin_domain" => "dynamic.test",
          "server" => %{
            "id" => "https://dynamic.test/_arblarg/servers/7",
            "name" => "dynamic-seven",
            "description" => "Remote dynamic test server",
            "is_public" => true,
            "member_count" => 3
          },
          "channels" => [],
          "messages" => []
        }
        |> sign_snapshot("k1", "dynamic-test-secret")

      body = Jason.encode!(payload)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/sync",
          domain: "dynamic.test",
          raw_body: body,
          secret: "dynamic-test-secret"
        )
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/sync", body)

      response = json_response(conn, 200)
      assert response["status"] == "ok"

      assert %FederationDiscoveredPeer{} =
               Repo.get_by(FederationDiscoveredPeer, domain: "dynamic.test")
    end

    test "rejects request auth refresh when discovery rotates to a quarantined identity", %{
      conn: conn
    } do
      current = Application.get_env(:elektrine, :messaging_federation)
      discovery_versions = :ets.new(:controller_arblarg_discovery_versions, [:set, :public])
      :ets.insert(discovery_versions, {:secret, "first-dynamic-secret"})

      Application.put_env(
        :elektrine,
        :messaging_federation,
        current
        |> Keyword.put(:peers, [])
        |> Keyword.put(:dns_identity_fetcher, fn
          "_arblarg.swap.test", "swap.test" ->
            [{:secret, secret}] = :ets.lookup(discovery_versions, :secret)

            [
              authenticated_dns_identity_proof(dynamic_discovery_document("swap.test", secret))
            ]

          _name, _domain ->
            []
        end)
        |> Keyword.put(:discovery_fetcher, fn
          "swap.test", _urls ->
            [{:secret, secret}] = :ets.lookup(discovery_versions, :secret)
            {:ok, dynamic_discovery_document("swap.test", secret)}

          _domain, _urls ->
            {:error, :not_found}
        end)
      )

      on_exit(fn ->
        if :ets.info(discovery_versions) != :undefined do
          :ets.delete(discovery_versions)
        end

        Application.put_env(:elektrine, :messaging_federation, current)
      end)

      assert {:ok, _peer} = Federation.discover_peer("swap.test")
      :ets.insert(discovery_versions, {:secret, "second-dynamic-secret"})

      payload =
        %{
          "version" => 1,
          "origin_domain" => "swap.test",
          "server" => %{
            "id" => "https://swap.test/_arblarg/servers/7",
            "name" => "swap-seven"
          },
          "channels" => [],
          "messages" => []
        }
        |> sign_snapshot("k1", "second-dynamic-secret")

      body = Jason.encode!(payload)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/sync",
          domain: "swap.test",
          raw_body: body,
          secret: "second-dynamic-secret"
        )
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/sync", body)

      _response = json_response(conn, 401)

      assert %FederationDiscoveredPeer{trust_state: "replaced"} =
               Repo.get_by(FederationDiscoveredPeer, domain: "swap.test")

      assert is_nil(Federation.incoming_peer("swap.test"))
    end

    test "rejects snapshots without governance and stream_positions", %{conn: conn} do
      payload =
        %{
          "version" => 1,
          "origin_domain" => "remote.test",
          "server" => %{
            "id" => "https://remote.test/_arblarg/servers/17",
            "name" => "missing-checkpoints"
          },
          "channels" => [],
          "messages" => []
        }
        |> sign_snapshot_exact("k1", "test-shared-secret")

      body = Jason.encode!(payload)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/sync", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/sync", body)

      response = json_response(conn, 400)
      assert response["code"] == "invalid_snapshot_governance"
    end
  end

  describe "POST /_arblarg/events" do
    test "applies valid server.upsert event and updates mirrored server", %{conn: conn} do
      event = server_upsert_event("evt-1", 1, "remote-room-v1")
      body = Jason.encode!(event)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/events", body)

      response = json_response(conn, 200)
      assert response["status"] == "applied"

      mirror =
        Repo.get_by(Server, federation_id: "https://remote.test/_arblarg/servers/77")

      assert mirror
      assert mirror.name == "remote-room-v1"
      assert mirror.is_federated_mirror == true
    end

    test "is idempotent for duplicate event ids", %{conn: conn} do
      event = server_upsert_event("evt-dup-1", 1, "dup-room")
      body = Jason.encode!(event)

      conn1 =
        conn
        |> signed_federation_headers("POST", "/_arblarg/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/events", body)

      assert json_response(conn1, 200)["status"] == "applied"

      conn2 =
        build_conn()
        |> signed_federation_headers("POST", "/_arblarg/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/events", body)

      assert json_response(conn2, 200)["status"] == "duplicate"
    end

    test "rejects sequence gaps per stream", %{conn: conn} do
      event = server_upsert_event("evt-gap-2", 2, "gap-room")
      body = Jason.encode!(event)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/events", body)

      _response = json_response(conn, 409)
    end

    test "requires envelope signatures for Arblarg protocol envelopes", %{conn: conn} do
      event =
        server_upsert_event("evt-arblarg-nosig", 1, "strict-room")
        |> Map.delete("signature")

      body = Jason.encode!(event)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/events", body)

      response = json_response(conn, 400)
      assert response["error"] == "Invalid event signature"
    end

    test "rejects server ownership conflicts for existing mirrored ids", %{conn: conn} do
      {:ok, _existing_server} =
        %Server{}
        |> Server.changeset(%{
          name: "existing-mirror",
          federation_id: "https://remote.test/_arblarg/servers/77",
          origin_domain: "different-origin.test",
          is_federated_mirror: true
        })
        |> Repo.insert()

      event = server_upsert_event("evt-origin-conflict-1", 1, "remote-room-v1")
      body = Jason.encode!(event)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/events", body)

      response = json_response(conn, 409)
      assert response["error"] == "Federation origin conflict for mirrored resource"
    end

    test "returns forbidden when a remote actor is not authorized for the room", %{conn: conn} do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "local-authority"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "ops",
          description: "private room",
          is_public: false
        })

      {:ok, snapshot} = Federation.build_server_snapshot(server.id, messages_per_channel: 1)
      server_id = snapshot["server"]["id"]
      channel_id = get_in(snapshot, ["channels", Access.at(0), "id"])

      event =
        sign_remote_event(
          "message.create",
          "channel:#{channel_id}",
          1,
          %{
            "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
            "message" => %{
              "id" => "https://remote.test/_arblarg/messages/999",
              "channel_id" => channel_id,
              "content" => "unauthorized",
              "message_type" => "text",
              "attachments" => [],
              "sender" => canonical_actor("alice", "remote.test")
            }
          },
          event_id: "evt-room-auth-1"
        )

      body = Jason.encode!(event)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/events", body)

      response = json_response(conn, 403)
      assert response["code"] == "not_authorized_for_room"
      assert response["error"] == "Remote actor is not authorized for this room"
      refute Repo.get_by(Elektrine.Messaging.ChatMessage, conversation_id: channel.id)
    end
  end

  describe "POST /_arblarg/events/batch" do
    test "applies ordered event batches and returns per-event statuses", %{conn: conn} do
      batch = %{
        "version" => 1,
        "batch_id" => "batch-1",
        "events" => [
          server_upsert_event("evt-batch-1", 1, "batch-room-v1"),
          server_upsert_event("evt-batch-2", 2, "batch-room-v2")
        ]
      }

      body = Jason.encode!(batch)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/events/batch", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/events/batch", body)

      response = json_response(conn, 200)

      assert response["batch_id"] == "batch-1"
      assert response["event_count"] == 2
      assert response["counts"]["applied"] == 2
      assert Enum.map(response["results"], & &1["status"]) == ["applied", "applied"]

      mirror =
        Repo.get_by(Server, federation_id: "https://remote.test/_arblarg/servers/77")

      assert mirror.name == "batch-room-v2"
    end

    test "accepts CBOR batches and returns CBOR summaries", %{conn: conn} do
      batch = %{
        "version" => 1,
        "batch_id" => "batch-cbor-1",
        "events" => [server_upsert_event("evt-batch-cbor-1", 1, "batch-room-cbor")]
      }

      body = CBOR.encode(batch)

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/events/batch", raw_body: body)
        |> put_req_header("content-type", "application/arblarg-batch+cbor")
        |> post("/_arblarg/events/batch", body)

      assert response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/arblarg-batch+cbor")

      assert {:ok, response, ""} = CBOR.decode(conn.resp_body)
      assert response["batch_id"] == "batch-cbor-1"
      assert response["counts"]["applied"] == 1
    end

    test "rejects CBOR batches with trailing bytes", %{conn: conn} do
      batch = %{
        "version" => 1,
        "batch_id" => "batch-cbor-trailing",
        "events" => [
          server_upsert_event("evt-batch-cbor-trailing", 1, "batch-room-cbor-trailing")
        ]
      }

      body = CBOR.encode(batch) <> <<0>>

      conn =
        conn
        |> signed_federation_headers("POST", "/_arblarg/events/batch", raw_body: body)
        |> put_req_header("content-type", "application/arblarg-batch+cbor")
        |> post("/_arblarg/events/batch", body)

      response = json_response(conn, 400)
      assert response["code"] == "invalid_payload"
    end
  end

  describe "POST /_arblarg/ephemeral" do
    test "applies room presence and typing updates without durable event replay", %{conn: conn} do
      bootstrap_event = server_upsert_event("evt-ephemeral-bootstrap", 1, "ephemeral-room")
      bootstrap_body = Jason.encode!(bootstrap_event)

      assert "applied" ==
               (conn
                |> signed_federation_headers("POST", "/_arblarg/events",
                  raw_body: bootstrap_body
                )
                |> put_req_header("content-type", "application/json")
                |> post("/_arblarg/events", bootstrap_body)
                |> json_response(200))["status"]

      mirror =
        Repo.get_by(Server, federation_id: "https://remote.test/_arblarg/servers/77")

      mirror_channel =
        Repo.get_by(Elektrine.Messaging.Conversation,
          federated_source: "https://remote.test/_arblarg/channels/10"
        )

      typing_actor =
        %Elektrine.ActivityPub.Actor{}
        |> Elektrine.ActivityPub.Actor.changeset(%{
          uri: "https://remote.test/users/typing-bot",
          username: "typing-bot",
          domain: "remote.test",
          inbox_url: "https://remote.test/users/typing-bot/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Elektrine.Messaging.FederationMembershipState{
        conversation_id: mirror_channel.id,
        remote_actor_id: typing_actor.id,
        origin_domain: "remote.test",
        role: "member",
        state: "active",
        joined_at_remote: timestamp,
        updated_at_remote: timestamp,
        metadata: %{}
      })

      Phoenix.PubSub.subscribe(Elektrine.PubSub, PubSubTopics.conversation(mirror_channel.id))

      payload = %{
        "version" => 1,
        "batch_id" => "ephemeral-1",
        "items" => [
          %{
            "event_type" => "presence.update",
            "origin_domain" => "remote.test",
            "payload" => %{
              "refs" => %{
                "server_id" => mirror.federation_id,
                "channel_id" => "https://remote.test/_arblarg/channels/10"
              },
              "presence" => %{
                "actor" => canonical_actor("typing-bot", "remote.test"),
                "status" => "online",
                "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            }
          },
          %{
            "event_type" => "typing.start",
            "origin_domain" => "remote.test",
            "payload" => %{
              "refs" => %{
                "server_id" => mirror.federation_id,
                "channel_id" => "https://remote.test/_arblarg/channels/10"
              },
              "actor" => canonical_actor("typing-bot", "remote.test"),
              "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "ttl_ms" => 3000
            }
          }
        ]
      }

      body = Jason.encode!(payload)

      response =
        build_conn()
        |> signed_federation_headers("POST", "/_arblarg/ephemeral", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/ephemeral", body)
        |> json_response(200)

      assert response["counts"]["applied"] == 2
      assert_receive {:federation_presence_update, presence_payload}, 1_000
      assert presence_payload.conversation_id == mirror_channel.id
      assert presence_payload.status == "online"
      assert_receive {:user_typing, remote_key, _label}, 1_000
      assert String.starts_with?(remote_key, "remote:")

      assert Repo.get_by(FederationRoomPresenceState,
               conversation_id: mirror_channel.id,
               remote_actor_id: typing_actor.id,
               status: "online"
             )
    end

    test "rejects legacy ephemeral items that send data instead of payload", %{conn: conn} do
      bootstrap_event = server_upsert_event("evt-ephemeral-legacy-bootstrap", 1, "ephemeral-room")
      bootstrap_body = Jason.encode!(bootstrap_event)

      assert "applied" ==
               (conn
                |> signed_federation_headers("POST", "/_arblarg/events",
                  raw_body: bootstrap_body
                )
                |> put_req_header("content-type", "application/json")
                |> post("/_arblarg/events", bootstrap_body)
                |> json_response(200))["status"]

      payload = %{
        "version" => 1,
        "batch_id" => "ephemeral-legacy",
        "items" => [
          %{
            "event_type" => "typing.start",
            "origin_domain" => "remote.test",
            "data" => %{
              "refs" => %{
                "server_id" => "https://remote.test/_arblarg/servers/77",
                "channel_id" => "https://remote.test/_arblarg/channels/10"
              },
              "actor" => canonical_actor("typing-bot", "remote.test"),
              "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "ttl_ms" => 3000
            }
          }
        ]
      }

      body = Jason.encode!(payload)

      response =
        build_conn()
        |> signed_federation_headers("POST", "/_arblarg/ephemeral", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/_arblarg/ephemeral", body)
        |> json_response(200)

      assert response["counts"]["error"] == 1
      assert response["error_counts"]["invalid_event_payload"] == 1
      assert [%{"status" => "error", "code" => "invalid_event_payload"}] = response["results"]
    end
  end

  describe "GET /_arblarg/servers/:server_id/snapshot" do
    test "returns snapshot for local server when request is signed", %{conn: conn} do
      owner = AccountsFixtures.user_fixture()

      {:ok, server} =
        Messaging.create_server(owner.id, %{name: "local-federated", is_public: true})

      conn =
        conn
        |> signed_federation_headers(
          "GET",
          "/_arblarg/servers/#{server.id}/snapshot"
        )
        |> get("/_arblarg/servers/#{server.id}/snapshot")

      response = json_response(conn, 200)
      assert response["version"] == 1
      assert response["server"]["name"] == "local-federated"
      assert is_list(response["channels"])
      assert is_map(response["governance"])
      assert is_list(response["stream_positions"])
      assert response["signature"]["algorithm"] == "ed25519"
    end

    test "filters unsupported snapshot extensions for the requesting peer", %{conn: conn} do
      current = Application.get_env(:elektrine, :messaging_federation)
      owner = AccountsFixtures.user_fixture()

      {:ok, server} =
        Messaging.create_server(owner.id, %{name: "extension-filtered", is_public: true})

      bootstrap_event_type = ArblargSDK.bootstrap_server_upsert_event_type()

      Repo.insert!(%FederationExtensionEvent{
        event_type: bootstrap_event_type,
        origin_domain: Federation.local_domain(),
        event_key: "controller-bootstrap:#{server.id}",
        payload: %{"server" => %{"id" => "server-#{server.id}"}},
        server_id: server.id
      })

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.put(current, :peers, [
          %{
            "domain" => "remote.test",
            "base_url" => "https://remote.test",
            "shared_secret" => "test-shared-secret",
            "supported_event_types" => ArblargSDK.core_event_types(),
            "active_outbound_key_id" => "k1",
            "keys" => [
              %{"id" => "k1", "secret" => "test-shared-secret", "active_outbound" => true}
            ],
            "allow_incoming" => true,
            "allow_outgoing" => true
          }
        ])
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, current)
      end)

      conn =
        conn
        |> signed_federation_headers(
          "GET",
          "/_arblarg/servers/#{server.id}/snapshot"
        )
        |> get("/_arblarg/servers/#{server.id}/snapshot")

      response = json_response(conn, 200)
      assert response["extensions"] == []
      assert response["signature"]["algorithm"] == "ed25519"
    end
  end

  describe "GET /_arblarg/streams/events" do
    test "exports compact ref-based stream events for replay", %{conn: conn} do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "fast-lane"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{name: "general", description: "x"})

      {:ok, message} =
        Messaging.create_chat_text_message(channel.id, owner.id, "hello compact federation")

      local_domain = Federation.local_domain()
      server_id = Elektrine.Messaging.Federation.Utils.server_federation_id(server.id)
      channel_id = Elektrine.Messaging.Federation.Utils.channel_federation_id(channel.id)
      message_id = Elektrine.Messaging.Federation.Utils.message_federation_id(message.id)
      stream_id = Elektrine.Messaging.Federation.Utils.channel_stream_id(channel.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      outbox =
        Repo.insert!(%FederationOutboxEvent{
          event_id: "evt-#{Ecto.UUID.generate()}",
          event_type: "message.create",
          stream_id: stream_id,
          sequence: 1,
          payload: %{
            "protocol" => ArblargSDK.protocol_name(),
            "protocol_id" => ArblargSDK.protocol_id(),
            "protocol_version" => ArblargSDK.protocol_version(),
            "event_id" => "evt-#{Ecto.UUID.generate()}",
            "event_type" => "message.create",
            "origin_domain" => local_domain,
            "stream_id" => stream_id,
            "sequence" => 1,
            "sent_at" => DateTime.to_iso8601(now),
            "idempotency_key" => "idem-#{Ecto.UUID.generate()}",
            "payload" => %{
              "refs" => %{"server_id" => server_id, "channel_id" => channel_id},
              "message" => %{
                "id" => message_id,
                "channel_id" => channel_id,
                "content" => message.content,
                "sender" => canonical_actor(owner.username, local_domain)
              }
            }
          },
          target_domains: ["remote.test"],
          delivered_domains: [],
          attempt_count: 0,
          max_attempts: 8,
          status: "pending",
          next_retry_at: now,
          partition_month: Date.new!(now.year, now.month, 1)
        })

      query_string =
        URI.encode_query(%{
          "stream_id" => outbox.stream_id,
          "after_sequence" => Integer.to_string(max(outbox.sequence - 1, 0)),
          "limit" => "10"
        })

      conn =
        conn
        |> signed_federation_headers("GET", "/_arblarg/streams/events",
          query_string: query_string
        )
        |> get("/_arblarg/streams/events?#{query_string}")

      response = json_response(conn, 200)

      assert response["stream_id"] == outbox.stream_id
      assert response["after_sequence"] == max(outbox.sequence - 1, 0)
      assert response["events"] |> length() == 1

      [event] = response["events"]

      assert get_in(event, ["payload", "refs", "server_id"]) ==
               outbox.payload["payload"]["refs"]["server_id"]

      assert get_in(event, ["payload", "refs", "channel_id"]) ==
               outbox.payload["payload"]["refs"]["channel_id"]

      refute get_in(event, ["payload", "server"])
      refute get_in(event, ["payload", "channel"])
    end
  end

  describe "GET /_arblarg/servers/public" do
    test "returns only local public servers", %{conn: conn} do
      owner = AccountsFixtures.user_fixture()

      {:ok, local_public} =
        Messaging.create_server(owner.id, %{name: "directory-local", is_public: true})

      {:ok, _local_private} =
        Messaging.create_server(owner.id, %{name: "directory-private", is_public: false})

      {:ok, _mirror_public} =
        %Server{}
        |> Server.changeset(%{
          name: "directory-remote-mirror",
          is_public: true,
          member_count: 13,
          federation_id: "https://remote.test/_arblarg/servers/501",
          origin_domain: "remote.test",
          is_federated_mirror: true
        })
        |> Repo.insert()

      conn = get(conn, "/_arblarg/servers/public")
      response = json_response(conn, 200)

      assert response["version"] == 1
      assert response["origin_domain"] == Federation.local_domain()
      assert Enum.any?(response["servers"], &(&1["name"] == "directory-local"))
      refute Enum.any?(response["servers"], &(&1["name"] == "directory-private"))
      refute Enum.any?(response["servers"], &(&1["name"] == "directory-remote-mirror"))

      entry = Enum.find(response["servers"], &(&1["name"] == "directory-local"))
      assert entry["server_id"] == local_public.id
      assert entry["origin_domain"] == Federation.local_domain()
    end
  end

  describe "GET /.well-known/_arblarg" do
    test "returns discovery metadata", %{conn: conn} do
      conn = get(conn, "/.well-known/_arblarg")
      response = json_response(conn, 200)

      assert response["version"] == 1
      assert response["domain"] == Elektrine.ActivityPub.instance_domain()
      assert response["protocol"] == ArblargSDK.protocol_name()
      assert response["protocol_id"] == "arblarg"
      assert response["identity"]["current_key_id"] == "k1"
      assert is_binary(response["endpoints"]["events"])
      assert is_binary(response["endpoints"]["events_batch"])
      assert is_binary(response["endpoints"]["ephemeral"])
      assert is_binary(response["endpoints"]["stream_events"])
      assert is_binary(response["endpoints"]["session_websocket"])
      assert is_binary(response["endpoints"]["profiles"])
      assert is_binary(response["endpoints"]["public_servers"])
      refute Map.has_key?(response, "profiles")
      assert response["features"]["relay_transport"] == true
      assert response["features"]["batched_event_delivery"] == true
      assert response["features"]["stream_catch_up"] == true
      assert response["features"]["binary_event_batches"] == true
      assert response["features"]["read_cursors"] == true
      assert response["features"]["ephemeral_lane"] == true
      assert response["features"]["origin_owned_identifiers"] == true
      assert response["features"]["signed_snapshots"] == true
      assert response["limits"]["max_batch_events"] >= 1
      assert "session_websocket" in response["transport_profiles"]["preferred_order"]

      assert String.ends_with?(
               response["endpoints"]["session_websocket"],
               "/_arblarg/session"
             )

      assert response["transport_profiles"]["session_websocket"]["framing"] ==
               "arblarg_websocket_stream_session"

      assert response["transport_profiles"]["session_websocket"]["request_path"] ==
               "/_arblarg/session"

      assert response["transport_profiles"]["session_websocket"]["delivery_ops"] == [
               "stream_batch",
               "deliver_ephemeral"
             ]

      assert response["transport_profiles"]["session_websocket"]["flow_control"][
               "max_inflight_batches"
             ] >= 1
    end

    test "serves version-pinned discovery document", %{conn: conn} do
      conn = get(conn, "/.well-known/_arblarg/1.0")
      response = json_response(conn, 200)

      assert response["protocol_id"] == "arblarg"
      assert response["default_protocol_label"] == "arblarg/1.0"
      assert response["default_protocol_version"] == "1.0"
      assert response["protocol"] == ArblargSDK.protocol_name()
    end

    test "returns public event schema documents", %{conn: conn} do
      conn = get(conn, "/_arblarg/1.0/schemas/message.create")
      response = json_response(conn, 200)

      assert response["title"] == "Arblarg message.create payload"
      assert "required" in Map.keys(response)
    end

    test "returns profile badges endpoint", %{conn: conn} do
      conn = get(conn, "/_arblarg/profiles")
      response = json_response(conn, 200)

      assert response["protocol_id"] == "arblarg"
      assert response["profiles"] != []
      assert "arblarg-core/1.0" in response["compatibility_claims"]
      assert response["features"]["strict_profiles"] == true
      assert response["relay_transport"]["official_operator"] == "Relay Collective"

      community_profile =
        Enum.find(response["profiles"], &(&1["id"] == "arblarg-community/1.0"))

      assert is_map(community_profile)
      assert community_profile["status"] == "unverified"

      roles_extension =
        Enum.find(response["extensions"], &(&1["urn"] == "urn:arblarg:ext:roles:1"))

      assert is_map(roles_extension)
      assert roles_extension["conformance"]["status"] == "unverified"
      assert is_binary(roles_extension["conformance"]["suite_version"])

      relay_urls = response["relay_transport"]["official_relays"] |> Enum.map(& &1["url"])
      assert "https://relay-us.example.com" in relay_urls
    end

    test "gates compatibility claims when conformance is not marked passing", %{conn: conn} do
      current = Application.get_env(:elektrine, :messaging_federation)

      updated =
        current
        |> Keyword.put(:conformance_core_passed, false)

      Application.put_env(:elektrine, :messaging_federation, updated)

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, current)
      end)

      conn = get(conn, "/_arblarg/profiles")
      response = json_response(conn, 200)

      assert response["compatibility_claims"] == []
    end
  end

  defp signed_federation_headers(conn, method, path, opts \\ []) do
    timestamp = Integer.to_string(System.system_time(:second))
    domain = Keyword.get(opts, :domain, "remote.test")
    key_id = Keyword.get(opts, :key_id, "k1")
    secret = Keyword.get(opts, :secret, "test-shared-secret")
    raw_body = Keyword.get(opts, :raw_body, "")
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())
    query_string = Keyword.get(opts, :query_string, "")
    content_digest = Federation.body_digest(raw_body)

    signature =
      Federation.sign_payload(
        Federation.signature_payload(
          domain,
          method,
          path,
          query_string,
          timestamp,
          content_digest,
          request_id
        ),
        secret
      )

    conn
    |> put_req_header("x-arblarg-domain", domain)
    |> put_req_header("x-arblarg-key-id", key_id)
    |> put_req_header("x-arblarg-timestamp", timestamp)
    |> put_req_header("x-arblarg-content-digest", content_digest)
    |> put_req_header("x-arblarg-request-id", request_id)
    |> put_req_header("x-arblarg-signature-algorithm", "ed25519")
    |> put_req_header("x-arblarg-signature", signature)
  end

  defp dynamic_discovery_document(domain, secret) do
    {public_key, _private_key} = ArblargSDK.derive_keypair_from_secret(secret)
    base_url = "https://#{domain}"

    unsigned = %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_labels" => [ArblargSDK.protocol_label()],
      "default_protocol_label" => ArblargSDK.protocol_label(),
      "default_protocol_version" => ArblargSDK.protocol_version(),
      "version" => 1,
      "domain" => domain,
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
        "session_websocket" => "wss://#{domain}/_arblarg/session",
        "snapshot_template" => "#{base_url}/_arblarg/servers/{server_id}/snapshot",
        "public_servers" => "#{base_url}/_arblarg/servers/public",
        "profiles" => "#{base_url}/_arblarg/profiles",
        "schema_template" => "#{base_url}/_arblarg/{version}/schemas/{name}"
      }
    }

    Map.put(unsigned, "signature", %{
      "algorithm" => "ed25519",
      "key_id" => "k1",
      "value" =>
        unsigned
        |> ArblargSDK.canonical_json_payload()
        |> ArblargSDK.sign_payload(secret)
    })
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

    sign_snapshot_exact(payload, key_id, secret)
  end

  defp sign_snapshot_exact(payload, key_id, secret)
       when is_map(payload) and is_binary(key_id) and is_binary(secret) do
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

  defp server_upsert_event(event_id, sequence, server_name) do
    server_id = "https://remote.test/_arblarg/servers/77"
    stream_id = "server:#{server_id}"

    sign_remote_event(
      "server.upsert",
      stream_id,
      sequence,
      %{
        "server" => %{
          "id" => server_id,
          "name" => server_name,
          "description" => "Remote event test server",
          "is_public" => true,
          "member_count" => 4
        },
        "channels" => [
          %{
            "id" => "https://remote.test/_arblarg/channels/10",
            "name" => "general",
            "position" => 0
          }
        ]
      },
      event_id: event_id
    )
  end

  defp sign_remote_event(event_type, stream_id, sequence, payload, opts) do
    unsigned = %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "event_id" => Keyword.get(opts, :event_id, "evt-#{Ecto.UUID.generate()}"),
      "event_type" => event_type,
      "origin_domain" => "remote.test",
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "idempotency_key" => Keyword.get(opts, :idempotency_key, "idem-#{Ecto.UUID.generate()}"),
      "payload" => payload
    }

    ArblargSDK.sign_event_envelope(unsigned, "k1", "test-shared-secret")
  end
end
