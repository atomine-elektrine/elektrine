defmodule ElektrineDNSWeb.API.DNSControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer
  alias Elektrine.DNS

  describe "external DNS API" do
    test "lists zones with read:dns scope", %{conn: conn} do
      user = user_fixture()
      {:ok, zone} = DNS.create_zone(user, %{"domain" => "example.com"})

      conn = conn |> with_pat(user.id, ["read:dns"]) |> get("/api/ext/v1/dns/zones")

      assert %{"data" => %{"zones" => zones}} = json_response(conn, 200)
      assert Enum.any?(zones, &(&1["id"] == zone.id))

      assert Enum.any?(
               zones,
               &(&1["domain"] == DNS.builtin_user_zone_domain(user) and &1["builtin"] == true)
             )
    end

    test "creates and updates records with write:dns scope", %{conn: conn} do
      user = user_fixture()
      {:ok, zone} = DNS.create_zone(user, %{"domain" => "example.net"})

      create_conn =
        conn
        |> with_pat(user.id, ["write:dns"])
        |> post("/api/ext/v1/dns/zones/#{zone.id}/records", %{
          "record" => %{"name" => "www", "type" => "A", "content" => "203.0.113.10", "ttl" => 300}
        })

      assert %{"data" => %{"record" => record}} = json_response(create_conn, 201)
      assert record["name"] == "www"

      update_conn =
        conn
        |> with_pat(user.id, ["write:dns"])
        |> put("/api/ext/v1/dns/zones/#{zone.id}/records/#{record["id"]}", %{
          "record" => %{"name" => "www", "type" => "A", "content" => "203.0.113.99", "ttl" => 600}
        })

      assert %{"data" => %{"record" => updated}} = json_response(update_conn, 200)
      assert updated["content"] == "203.0.113.99"
      assert updated["ttl"] == 600
    end

    test "rejects apex routing changes on the built-in user zone", %{conn: conn} do
      user = user_fixture()
      [zone | _] = DNS.list_user_zones(user)

      conn =
        conn
        |> with_pat(user.id, ["write:dns"])
        |> post("/api/ext/v1/dns/zones/#{zone.id}/records", %{
          "record" => %{"name" => "@", "type" => "A", "content" => "203.0.113.10", "ttl" => 300}
        })

      assert %{"error" => error} = json_response(conn, 422)
      assert error["code"] == "validation_failed"

      assert error["details"]["name"] == [
               "the apex host is reserved for Elektrine profile routing; only TXT and CAA are allowed there"
             ]
    end

    test "allows apex A records on the built-in user zone after dns handoff", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = DNS.update_builtin_user_zone_mode(user, "external_dns")
      [zone | _] = DNS.list_user_zones(user)

      conn =
        conn
        |> with_pat(user.id, ["write:dns"])
        |> post("/api/ext/v1/dns/zones/#{zone.id}/records", %{
          "record" => %{"name" => "@", "type" => "A", "content" => "203.0.113.10", "ttl" => 300}
        })

      assert %{"data" => %{"record" => record}} = json_response(conn, 201)
      assert record["name"] == "@"
      assert record["type"] == "A"
    end

    test "rejects dns endpoints without dns scopes", %{conn: conn} do
      user = user_fixture()

      conn = conn |> with_pat(user.id, ["read:account"]) |> get("/api/ext/v1/dns/zones")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "insufficient_scope"
    end
  end

  defp with_pat(conn, user_id, scopes) do
    {:ok, token} =
      Developer.create_api_token(user_id, %{
        name: "test-token-#{System.unique_integer([:positive])}",
        scopes: scopes
      })

    put_req_header(conn, "authorization", "Bearer #{token.token}")
  end
end
