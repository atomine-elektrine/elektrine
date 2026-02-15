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

      conn =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/sync")
        |> post("/federation/messaging/sync", payload)

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

      conn =
        conn
        |> signed_federation_headers(
          "POST",
          "/federation/messaging/sync",
          key_id: "k0",
          secret: "old-shared-secret"
        )
        |> post("/federation/messaging/sync", payload)

      response = json_response(conn, 200)
      assert response["status"] == "ok"
    end
  end

  describe "POST /federation/messaging/events" do
    test "applies valid server.upsert event and updates mirrored server", %{conn: conn} do
      event = server_upsert_event("evt-1", 1, "remote-room-v1")

      conn =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events")
        |> post("/federation/messaging/events", event)

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

      conn1 =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events")
        |> post("/federation/messaging/events", event)

      assert json_response(conn1, 200)["status"] == "applied"

      conn2 =
        build_conn()
        |> signed_federation_headers("POST", "/federation/messaging/events")
        |> post("/federation/messaging/events", event)

      assert json_response(conn2, 200)["status"] == "duplicate"
    end

    test "rejects sequence gaps per stream", %{conn: conn} do
      event = server_upsert_event("evt-gap-2", 2, "gap-room")

      conn =
        conn
        |> signed_federation_headers("POST", "/federation/messaging/events")
        |> post("/federation/messaging/events", event)

      _response = json_response(conn, 409)
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

  describe "GET /.well-known/elektrine-messaging-federation" do
    test "returns discovery metadata", %{conn: conn} do
      conn = get(conn, "/.well-known/elektrine-messaging-federation")
      response = json_response(conn, 200)

      assert response["version"] == 1
      assert response["domain"] == Elektrine.ActivityPub.instance_domain()
      assert response["features"]["event_federation"] == true
      assert response["identity"]["current_key_id"] == "k1"
      assert is_binary(response["endpoints"]["events"])
    end
  end

  defp signed_federation_headers(conn, method, path, opts \\ []) do
    timestamp = Integer.to_string(System.system_time(:second))
    domain = "remote.test"
    key_id = Keyword.get(opts, :key_id, "k1")
    secret = Keyword.get(opts, :secret, "test-shared-secret")

    signature =
      Federation.sign_payload(
        Federation.signature_payload(domain, method, path, "", timestamp),
        secret
      )

    conn
    |> put_req_header("x-elektrine-federation-domain", domain)
    |> put_req_header("x-elektrine-federation-key-id", key_id)
    |> put_req_header("x-elektrine-federation-timestamp", timestamp)
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
