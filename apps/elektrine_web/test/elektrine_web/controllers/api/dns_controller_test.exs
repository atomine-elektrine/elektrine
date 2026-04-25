defmodule ElektrineDNSWeb.API.DNSControllerTestDKIM do
  def generate_domain_key_material do
    %{selector: "default", public_key: "PUBLICKEY", private_key: "PRIVATEKEY"}
  end

  def public_key_dns_value(key), do: key
  def mx_host, do: "mail.example.com"
  def sync_domain(_domain, _selector, _private_key), do: :ok
end

defmodule ElektrineDNSWeb.API.DNSControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer
  alias Elektrine.DNS

  setup do
    old_dkim = Application.get_env(:elektrine, :managed_dns_dkim_module)
    old_master = Application.get_env(:elektrine, :encryption_master_secret)
    old_salt = Application.get_env(:elektrine, :encryption_key_salt)

    Application.put_env(
      :elektrine,
      :managed_dns_dkim_module,
      ElektrineDNSWeb.API.DNSControllerTestDKIM
    )

    Application.put_env(:elektrine, :encryption_master_secret, "test-master-secret-0123456789")
    Application.put_env(:elektrine, :encryption_key_salt, "test-key-salt-0123456789")

    on_exit(fn ->
      restore_env(:managed_dns_dkim_module, old_dkim)
      restore_env(:encryption_master_secret, old_master)
      restore_env(:encryption_key_salt, old_salt)
    end)

    :ok
  end

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

    test "serializes type-specific DNSSEC and TLS fields", %{conn: conn} do
      user = user_fixture()
      {:ok, zone} = DNS.create_zone(user, %{"domain" => "typed-fields.example"})

      conn =
        conn
        |> with_pat(user.id, ["write:dns"])
        |> post("/api/ext/v1/dns/zones/#{zone.id}/records", %{
          "record" => %{
            "name" => "_443._tcp.www",
            "type" => "TLSA",
            "content" => "A1B2C3D4",
            "ttl" => 300,
            "usage" => 3,
            "selector" => 1,
            "matching_type" => 1
          }
        })

      assert %{"data" => %{"record" => record}} = json_response(conn, 201)
      assert record["usage"] == 3
      assert record["selector"] == 1
      assert record["matching_type"] == 1
    end

    test "redacts managed service secrets in API responses", %{conn: conn} do
      user = user_fixture()
      {:ok, zone} = DNS.create_zone(user, %{"domain" => "redacted.example"})

      apply_conn =
        conn
        |> with_pat(user.id, ["write:dns"])
        |> post("/api/ext/v1/dns/zones/#{zone.id}/services/mail/apply", %{"service_config" => %{}})

      assert %{"data" => %{"service_config" => service_config}} = json_response(apply_conn, 200)
      assert service_config["settings"]["dkim_private_key"] == "[redacted]"
      refute service_config["settings"]["dkim_private_key"] == "PRIVATEKEY"

      show_conn =
        conn
        |> recycle()
        |> with_pat(user.id, ["read:dns"])
        |> get("/api/ext/v1/dns/zones/#{zone.id}")

      assert %{"data" => %{"zone" => api_zone}} = json_response(show_conn, 200)

      mail_config = Enum.find(api_zone["service_configs"], &(&1["service"] == "mail"))
      assert mail_config["settings"]["dkim_private_key"] == "[redacted]"

      mail_health = Enum.find(api_zone["service_health"], &(&1["service"] == "mail"))
      assert mail_health["settings"]["dkim_private_key"] == "[redacted]"
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

  defp restore_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_env(key, value), do: Application.put_env(:elektrine, key, value)
end
