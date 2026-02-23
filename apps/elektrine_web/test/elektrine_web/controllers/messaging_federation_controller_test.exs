defmodule ElektrineWeb.MessagingFederationControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Server
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
          "active_outbound_key_id" => "k1",
          "keys" => [
            %{"id" => "k1", "secret" => "test-shared-secret", "active_outbound" => true},
            %{"id" => "k0", "secret" => "old-shared-secret"}
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

  describe "POST /federation/messaging/sync" do
    test "accepts valid signed snapshot", %{conn: conn} do
      payload = %{
        "version" => 1,
        "origin_domain" => "remote.test",
        "server" => %{
          "id" => "https://remote.test/federation/messaging/servers/7",
          "name" => "remote-seven",
          "description" => "Remote test server",
          "is_public" => true,
          "member_count" => 3
        },
        "channels" => [
          %{
            "id" => "https://remote.test/federation/messaging/channels/9",
            "name" => "general",
            "position" => 0
          }
        ],
        "messages" => []
      }

      body = Jason.encode!(payload)

      conn =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/sync", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/sync", body)

      response = json_response(conn, 200)
      assert response["status"] == "ok"
      assert is_integer(response["mirror_server_id"])
    end

    test "rejects invalid signature", %{conn: conn} do
      payload = %{
        "version" => 1,
        "origin_domain" => "remote.test",
        "server" => %{
          "id" => "https://remote.test/federation/messaging/servers/7",
          "name" => "remote-seven"
        },
        "channels" => [],
        "messages" => []
      }

      conn =
        conn
        |> put_req_header("x-elektrine-federation-domain", "remote.test")
        |> put_req_header(
          "x-elektrine-federation-timestamp",
          Integer.to_string(System.system_time(:second))
        )
        |> put_req_header("x-elektrine-federation-signature", "invalid")
        |> post("/federation/messaging/sync", payload)

      _response = json_response(conn, 401)
    end

    test "accepts rotated key signatures by key id", %{conn: conn} do
      payload = %{
        "version" => 1,
        "origin_domain" => "remote.test",
        "server" => %{
          "id" => "https://remote.test/federation/messaging/servers/88",
          "name" => "rotated-key-server"
        },
        "channels" => [],
        "messages" => []
      }

      body = Jason.encode!(payload)

      conn =
        conn
        |> signed_federation_headers(
          "POST",
          "/federation/messaging/sync",
          raw_body: body,
          key_id: "k0",
          secret: "old-shared-secret"
        )
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/sync", body)

      response = json_response(conn, 200)
      assert response["status"] == "ok"
    end
  end

  describe "POST /federation/messaging/events" do
    test "applies valid server.upsert event and updates mirrored server", %{conn: conn} do
      event = server_upsert_event("evt-1", 1, "remote-room-v1")
      body = Jason.encode!(event)

      conn =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body)

      response = json_response(conn, 200)
      assert response["status"] == "applied"

      mirror =
        Repo.get_by(Server, federation_id: "https://remote.test/federation/messaging/servers/77")

      assert mirror
      assert mirror.name == "remote-room-v1"
      assert mirror.is_federated_mirror == true
    end

    test "is idempotent for duplicate event ids", %{conn: conn} do
      event = server_upsert_event("evt-dup-1", 1, "dup-room")
      body = Jason.encode!(event)

      conn1 =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body)

      assert json_response(conn1, 200)["status"] == "applied"

      conn2 =
        build_conn()
        |> signed_federation_headers("POST", "/federation/messaging/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body)

      assert json_response(conn2, 200)["status"] == "duplicate"
    end

    test "rejects sequence gaps per stream", %{conn: conn} do
      event = server_upsert_event("evt-gap-2", 2, "gap-room")
      body = Jason.encode!(event)

      conn =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body)

      _response = json_response(conn, 409)
    end

    test "requires envelope signatures for ARBP protocol envelopes", %{conn: conn} do
      legacy_event = server_upsert_event("evt-arbp-nosig", 1, "strict-room")

      event =
        legacy_event
        |> Map.put("protocol", "arblarg")
        |> Map.put("protocol_id", "arbp")
        |> Map.put("protocol_version", "1.0")
        |> Map.put("protocol_label", "arbp/1.0")
        |> Map.put("payload", legacy_event["data"])

      body = Jason.encode!(event)

      conn =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body)

      response = json_response(conn, 400)
      assert response["error"] == "Invalid event signature"
    end

    test "rejects server ownership conflicts for existing mirrored ids", %{conn: conn} do
      {:ok, _existing_server} =
        %Server{}
        |> Server.changeset(%{
          name: "existing-mirror",
          federation_id: "https://remote.test/federation/messaging/servers/77",
          origin_domain: "different-origin.test",
          is_federated_mirror: true
        })
        |> Repo.insert()

      event = server_upsert_event("evt-origin-conflict-1", 1, "remote-room-v1")
      body = Jason.encode!(event)

      conn =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events", raw_body: body)
        |> put_req_header("content-type", "application/json")
        |> post("/federation/messaging/events", body)

      response = json_response(conn, 409)
      assert response["error"] == "Federation origin conflict for mirrored resource"
    end
  end

  describe "GET /federation/messaging/servers/:server_id/snapshot" do
    test "returns snapshot for local server when request is signed", %{conn: conn} do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "local-federated"})

      conn =
        conn
        |> signed_federation_headers(
          "GET",
          "/federation/messaging/servers/#{server.id}/snapshot"
        )
        |> get("/federation/messaging/servers/#{server.id}/snapshot")

      response = json_response(conn, 200)
      assert response["version"] == 1
      assert response["server"]["name"] == "local-federated"
      assert is_list(response["channels"])
    end
  end

  describe "GET /federation/messaging/servers/public" do
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
          federation_id: "https://remote.test/federation/messaging/servers/501",
          origin_domain: "remote.test",
          is_federated_mirror: true
        })
        |> Repo.insert()

      conn = get(conn, "/federation/messaging/servers/public")
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

  describe "GET /.well-known/arblarg" do
    test "returns discovery metadata", %{conn: conn} do
      conn = get(conn, "/.well-known/arblarg")
      response = json_response(conn, 200)

      assert response["version"] == 1
      assert response["domain"] == Elektrine.ActivityPub.instance_domain()
      assert response["protocol"] == "arblarg"
      assert response["protocol_id"] == "arbp"
      assert response["identity"]["current_key_id"] == "k1"
      assert is_binary(response["endpoints"]["events"])
      assert is_binary(response["endpoints"]["profiles"])
      assert is_binary(response["endpoints"]["public_servers"])
      refute Map.has_key?(response, "profiles")
      assert response["features"]["relay_transport"] == true
    end

    test "serves legacy discovery aliases", %{conn: conn} do
      alias_response =
        conn
        |> get("/.well-known/elektrine")
        |> json_response(200)

      legacy_response =
        build_conn()
        |> get("/.well-known/elektrine-messaging-federation")
        |> json_response(200)

      assert alias_response["domain"] == legacy_response["domain"]
      assert alias_response["endpoints"] == legacy_response["endpoints"]
    end

    test "serves version-pinned discovery document", %{conn: conn} do
      conn = get(conn, "/.well-known/arblarg/1.0")
      response = json_response(conn, 200)

      assert response["protocol_id"] == "arbp"
      assert response["default_protocol_label"] == "arbp/1.0"
      assert response["default_protocol_version"] == "1.0"
      assert response["protocol"] == "arblarg"
    end

    test "returns public event schema documents", %{conn: conn} do
      conn = get(conn, "/federation/messaging/arblarg/1.0/schemas/message.create")
      response = json_response(conn, 200)

      assert response["title"] == "Arblarg message.create payload"
      assert "required" in Map.keys(response)
    end

    test "returns profile badges endpoint", %{conn: conn} do
      conn = get(conn, "/federation/messaging/arblarg/profiles")
      response = json_response(conn, 200)

      assert response["protocol_id"] == "arbp"
      assert response["profiles"] != []
      assert "arbp-core/1.0" in response["compatibility_claims"]
      assert response["features"]["strict_profiles"] == true
      assert response["relay_transport"]["official_operator"] == "Relay Collective"

      discord_profile = Enum.find(response["profiles"], &(&1["id"] == "arbp-discord/1.0"))
      assert is_map(discord_profile)
      assert discord_profile["status"] == "unverified"

      roles_extension = Enum.find(response["extensions"], &(&1["urn"] == "urn:arbp:ext:roles:1"))
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

      conn = get(conn, "/federation/messaging/arblarg/profiles")
      response = json_response(conn, 200)

      assert response["compatibility_claims"] == []
    end
  end

  defp signed_federation_headers(conn, method, path, opts \\ []) do
    timestamp = Integer.to_string(System.system_time(:second))
    domain = "remote.test"
    key_id = Keyword.get(opts, :key_id, "k1")
    secret = Keyword.get(opts, :secret, "test-shared-secret")
    raw_body = Keyword.get(opts, :raw_body, "")
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())
    content_digest = Federation.body_digest(raw_body)

    signature =
      Federation.sign_payload(
        Federation.signature_payload(
          domain,
          method,
          path,
          "",
          timestamp,
          content_digest,
          request_id
        ),
        secret
      )

    conn
    |> put_req_header("x-elektrine-federation-domain", domain)
    |> put_req_header("x-elektrine-federation-key-id", key_id)
    |> put_req_header("x-elektrine-federation-timestamp", timestamp)
    |> put_req_header("x-elektrine-federation-content-digest", content_digest)
    |> put_req_header("x-arblarg-request-id", request_id)
    |> put_req_header("x-arblarg-signature-algorithm", "ed25519")
    |> put_req_header("x-elektrine-federation-signature", signature)
  end

  defp server_upsert_event(event_id, sequence, server_name) do
    server_id = "https://remote.test/federation/messaging/servers/77"
    stream_id = "server:#{server_id}"

    %{
      "version" => 1,
      "event_id" => event_id,
      "event_type" => "server.upsert",
      "origin_domain" => "remote.test",
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "data" => %{
        "server" => %{
          "id" => server_id,
          "name" => server_name,
          "description" => "Remote event test server",
          "is_public" => true,
          "member_count" => 4
        },
        "channels" => [
          %{
            "id" => "https://remote.test/federation/messaging/channels/10",
            "name" => "general",
            "position" => 0
          }
        ]
      }
    }
  end
end
