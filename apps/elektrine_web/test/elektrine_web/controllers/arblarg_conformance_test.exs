defmodule ElektrineWeb.ArblargConformanceTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.Federation
  alias Elektrine.Repo

  @remote_domain "remote.test"
  @remote_key_id "rk1"
  @remote_secret "remote-signing-secret"

  setup do
    previous = Application.get_env(:elektrine, :messaging_federation)

    Application.put_env(
      :elektrine,
      :messaging_federation,
      enabled: true,
      identity_key_id: "local-k1",
      identity_shared_secret: "local-signing-secret",
      conformance_core_passed: true,
      peers: [
        %{
          "domain" => @remote_domain,
          "base_url" => "https://remote.test",
          "active_outbound_key_id" => @remote_key_id,
          "keys" => [
            %{"id" => @remote_key_id, "secret" => @remote_secret, "active_outbound" => true}
          ],
          "allow_incoming" => true,
          "allow_outgoing" => false
        }
      ]
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :messaging_federation, previous)
    end)

    :ok
  end

  describe "Arblarg v1 conformance" do
    test "CONF-001 discovery and schemas are published", %{conn: conn} do
      discovery =
        conn
        |> get("/.well-known/arblarg")
        |> json_response(200)

      assert discovery["protocol"] == ArblargSDK.protocol_name()
      assert discovery["protocol_id"] == "arblarg"
      assert discovery["default_protocol_label"] == "arblarg/1.0"
      assert "1.0" in discovery["protocol_versions"]
      assert "arblarg/1.0" in discovery["protocol_labels"]
      assert discovery["signature"]["algorithm"] == "ed25519"
      assert is_binary(discovery["signature"]["key_id"])
      assert is_binary(discovery["signature"]["value"])
      assert is_binary(discovery["endpoints"]["profiles"])
      assert is_binary(discovery["endpoints"]["schema_template"])
      assert discovery["features"]["relay_transport"] == true
      assert discovery["relay_transport"]["mode"] == "optional"
      assert discovery["relay_transport"]["community_hostable"] == true

      versioned =
        build_conn()
        |> get("/.well-known/arblarg/1.0")
        |> json_response(200)

      assert versioned["default_protocol_version"] == "1.0"

      schema =
        build_conn()
        |> get("/federation/messaging/arblarg/1.0/schemas/envelope")
        |> json_response(200)

      assert schema["title"] == "Arblarg Event Envelope"

      profiles =
        build_conn()
        |> get("/federation/messaging/arblarg/profiles")
        |> json_response(200)

      assert "arblarg-core/1.0" in profiles["compatibility_claims"]
      assert "message.create" in profiles["events"]["core"]
      assert profiles["features"]["wire_contract_frozen"] == true
      assert profiles["wire_contract"]["status"] == "stable"
      assert is_binary(profiles["schemas"]["envelope"])
      assert is_binary(profiles["schemas"]["role.upsert"])
    end

    test "CONF-002 signed core events are accepted", %{conn: conn} do
      event =
        build_event(
          "message.create",
          "channel:https://remote.test/federation/messaging/channels/conformance-1",
          1,
          "idem-conf-002",
          %{
            "server" => %{
              "id" => "https://remote.test/federation/messaging/servers/conformance-1",
              "name" => "Conformance",
              "is_public" => true
            },
            "channel" => %{
              "id" => "https://remote.test/federation/messaging/channels/conformance-1",
              "name" => "general",
              "position" => 0
            },
            "message" => %{
              "id" => "https://remote.test/federation/messaging/messages/conf-1",
              "channel_id" => "https://remote.test/federation/messaging/channels/conformance-1",
              "content" => "hello from arblarg",
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" => canonical_actor("alice", @remote_domain)
            }
          }
        )

      body = Jason.encode!(event)

      response =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events", body)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body)
        |> json_response(200)

      assert response["status"] == "applied"
    end

    test "CONF-003 replayed signed request is rejected", %{conn: conn} do
      event =
        build_event(
          "urn:arblarg:ext:bootstrap:1#server.upsert",
          "server:https://remote.test/federation/messaging/servers/conformance-2",
          1,
          "idem-conf-003",
          %{
            "server" => %{
              "id" => "https://remote.test/federation/messaging/servers/conformance-2",
              "name" => "Replay Conformance",
              "is_public" => true
            },
            "channels" => []
          }
        )

      body = Jason.encode!(event)
      timestamp = Integer.to_string(System.system_time(:second))
      request_id = Ecto.UUID.generate()

      first_conn =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events", body,
          timestamp: timestamp,
          request_id: request_id
        )
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body)

      assert json_response(first_conn, 200)["status"] == "applied"

      second_conn =
        build_conn()
        |> signed_federation_headers("POST", "/federation/messaging/events", body,
          timestamp: timestamp,
          request_id: request_id
        )
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body)

      _response = json_response(second_conn, 401)
    end

    test "CONF-004 idempotency_key deduplicates semantic retries", %{conn: conn} do
      stream_id = "channel:https://remote.test/federation/messaging/channels/conformance-4"

      event_one =
        build_event("message.create", stream_id, 1, "idem-conf-004", %{
          "server" => %{
            "id" => "https://remote.test/federation/messaging/servers/conformance-4",
            "name" => "Conformance",
            "is_public" => true
          },
          "channel" => %{
            "id" => "https://remote.test/federation/messaging/channels/conformance-4",
            "name" => "general",
            "position" => 0
          },
          "message" => %{
            "id" => "https://remote.test/federation/messaging/messages/conf-4",
            "channel_id" => "https://remote.test/federation/messaging/channels/conformance-4",
            "content" => "dedupe me",
            "message_type" => "text",
            "media_urls" => [],
            "media_metadata" => %{},
            "sender" => canonical_actor("alice", @remote_domain)
          }
        })

      body_one = Jason.encode!(event_one)

      assert "applied" ==
               (conn
                |> signed_federation_headers("POST", "/federation/messaging/events", body_one)
                |> put_req_header("content-type", "application/json")
                |> post("/federation/messaging/events", body_one)
                |> json_response(200))["status"]

      event_two =
        event_one
        |> Map.delete("signature")
        |> Map.put("event_id", "evt-#{Ecto.UUID.generate()}")
        |> Map.put("sequence", 2)
        |> ArblargSDK.sign_event_envelope(@remote_key_id, @remote_secret)

      body_two = Jason.encode!(event_two)

      response =
        build_conn()
        |> signed_federation_headers("POST", "/federation/messaging/events", body_two)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body_two)
        |> json_response(200)

      assert response["status"] == "duplicate"
    end

    test "CONF-005 read.cursor core event is accepted", %{conn: conn} do
      actor_uri = "https://remote.test/users/alice"

      {:ok, _actor} =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "alice",
          domain: @remote_domain,
          inbox_url: "https://remote.test/users/alice/inbox",
          public_key: "placeholder"
        })
        |> Repo.insert()

      stream_id = "channel:https://remote.test/federation/messaging/channels/conformance-5"

      create_event =
        build_event("message.create", stream_id, 1, "idem-conf-005-msg", %{
          "server" => %{
            "id" => "https://remote.test/federation/messaging/servers/conformance-5",
            "name" => "Conformance",
            "is_public" => true
          },
          "channel" => %{
            "id" => "https://remote.test/federation/messaging/channels/conformance-5",
            "name" => "general",
            "position" => 0
          },
          "message" => %{
            "id" => "https://remote.test/federation/messaging/messages/conf-5",
            "channel_id" => "https://remote.test/federation/messaging/channels/conformance-5",
            "content" => "mark me read",
            "message_type" => "text",
            "media_urls" => [],
            "media_metadata" => %{},
            "sender" => canonical_actor("bob", @remote_domain)
          }
        })

      create_body = Jason.encode!(create_event)

      assert "applied" ==
               (conn
                |> signed_federation_headers("POST", "/federation/messaging/events", create_body)
                |> put_req_header("content-type", "application/json")
                |> post("/federation/messaging/events", create_body)
                |> json_response(200))["status"]

      read_event =
        build_event("read.cursor", stream_id, 2, "idem-conf-005-read", %{
          "server" => %{
            "id" => "https://remote.test/federation/messaging/servers/conformance-5",
            "name" => "Conformance",
            "is_public" => true
          },
          "channel" => %{
            "id" => "https://remote.test/federation/messaging/channels/conformance-5",
            "name" => "general",
            "position" => 0
          },
          "read_through_message_id" => "https://remote.test/federation/messaging/messages/conf-5",
          "actor" => canonical_actor("alice", @remote_domain, uri: actor_uri),
          "read_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      read_body = Jason.encode!(read_event)

      response =
        build_conn()
        |> signed_federation_headers("POST", "/federation/messaging/events", read_body)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", read_body)
        |> json_response(200)

      assert response["status"] == "applied"
    end
  end

  defp build_event(event_type, stream_id, sequence, idempotency_key, payload) do
    unsigned = %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "event_id" => "evt-#{Ecto.UUID.generate()}",
      "event_type" => event_type,
      "origin_domain" => @remote_domain,
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "idempotency_key" => idempotency_key,
      "payload" => payload
    }

    ArblargSDK.sign_event_envelope(unsigned, @remote_key_id, @remote_secret)
  end

  defp signed_federation_headers(conn, method, path, body, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, Integer.to_string(System.system_time(:second)))
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())
    content_digest = Federation.body_digest(body)

    signature =
      Federation.signature_payload(
        @remote_domain,
        method,
        path,
        "",
        timestamp,
        content_digest,
        request_id
      )
      |> Federation.sign_payload(@remote_secret)

    conn
    |> put_req_header("x-arblarg-domain", @remote_domain)
    |> put_req_header("x-arblarg-key-id", @remote_key_id)
    |> put_req_header("x-arblarg-timestamp", timestamp)
    |> put_req_header("x-arblarg-content-digest", content_digest)
    |> put_req_header("x-arblarg-request-id", request_id)
    |> put_req_header("x-arblarg-signature-algorithm", "ed25519")
    |> put_req_header("x-arblarg-signature", signature)
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
end
