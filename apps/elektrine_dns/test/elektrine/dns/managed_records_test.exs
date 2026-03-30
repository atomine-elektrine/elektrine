defmodule Elektrine.DNS.TestDKIM do
  def generate_domain_key_material do
    %{selector: "default", public_key: "PUBLICKEY", private_key: "PRIVATEKEY"}
  end

  def public_key_dns_value(key), do: key
  def mx_host, do: "mail.example.com"
  def sync_domain(_domain, _selector, _private_key), do: :ok
end

defmodule Elektrine.DNS.ManagedRecordsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS

  setup do
    old = Application.get_env(:elektrine, :managed_dns_dkim_module)
    Application.put_env(:elektrine, :managed_dns_dkim_module, Elektrine.DNS.TestDKIM)
    on_exit(fn -> Application.put_env(:elektrine, :managed_dns_dkim_module, old) end)
    :ok
  end

  test "applies managed web records per zone" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain(), "default_ttl" => 600})

    assert {:ok, config} = DNS.apply_zone_service(zone, "web")
    assert config.service == "web"
    assert config.status == "ok"

    zone = DNS.get_zone(zone.id, user.id)
    [www] = Enum.filter(zone.records, &(&1.service == "web"))

    assert www.managed == true
    assert www.source == "system"
    assert www.name == "www"
    assert www.type == "CNAME"
    assert www.content == zone.domain
  end

  test "marks managed mail service as conflict when user record already exists" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    {:ok, _record} =
      DNS.create_record(zone, %{
        "name" => "@",
        "type" => "MX",
        "ttl" => 300,
        "content" => zone.domain,
        "priority" => 10
      })

    assert {:ok, config} = DNS.apply_zone_service(zone, "mail")
    assert config.status == "conflict"
    assert config.last_error =~ "MX @ conflicts"

    zone = DNS.get_zone(zone.id, user.id)
    refute Enum.any?(zone.records, &(&1.service == "mail" and &1.managed))
  end

  test "adopts an existing matching user rrset into managed web dns" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain(), "default_ttl" => 600})

    {:ok, record} =
      DNS.create_record(zone, %{
        "name" => "www",
        "type" => "CNAME",
        "ttl" => 600,
        "content" => zone.domain
      })

    assert {:ok, config} = DNS.apply_zone_service(zone, "web")
    assert config.status == "ok"

    zone = DNS.get_zone(zone.id, user.id)
    [www] = Enum.filter(zone.records, &(&1.name == "www" and &1.type == "CNAME"))

    assert www.id == record.id
    assert www.managed == true
    assert www.source == "system"
    assert www.service == "web"
    assert www.managed_key == "web:www"
  end

  test "adopts an existing matching user mx record into managed mail dns" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    {:ok, mx} =
      DNS.create_record(zone, %{
        "name" => "@",
        "type" => "MX",
        "ttl" => 300,
        "content" => "mail.example.com",
        "priority" => 10
      })

    assert {:ok, config} = DNS.apply_zone_service(zone, "mail")
    assert config.status == "ok"

    zone = DNS.get_zone(zone.id, user.id)
    adopted = Enum.find(zone.records, &(&1.id == mx.id))

    assert adopted.managed == true
    assert adopted.service == "mail"
    assert adopted.managed_key == "mail:mx"
  end

  test "disabling a managed service removes its records" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, _config} = DNS.apply_zone_service(zone, "mail")
    zone = DNS.get_zone(zone.id, user.id)
    assert Enum.any?(zone.records, &(&1.service == "mail" and &1.managed))

    assert {:ok, disabled} = DNS.disable_zone_service(zone, "mail")
    assert disabled.status == "disabled"

    zone = DNS.get_zone(zone.id, user.id)
    refute Enum.any?(zone.records, &(&1.service == "mail" and &1.managed))
  end

  test "managed mail service generates DKIM settings and TXT record" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, config} = DNS.apply_zone_service(zone, "mail")
    assert config.status == "ok"
    assert is_binary(config.settings["dkim_selector"])
    assert is_binary(config.settings["dkim_public_key"])
    assert is_binary(config.settings["dkim_private_key"])
    assert String.contains?(config.settings["dkim_value"], "v=DKIM1")

    zone = DNS.get_zone(zone.id, user.id)
    assert Enum.any?(zone.records, &(&1.service == "mail" and &1.managed_key == "mail:dkim"))

    assert Enum.any?(
             zone.records,
             &(&1.service == "mail" and &1.managed_key == "mail:mta-sts-txt")
           )

    assert Enum.any?(zone.records, &(&1.service == "mail" and &1.managed_key == "mail:tls-rpt"))

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.name == "_mta-sts" and
               String.starts_with?(record.content, "v=STSv1; id=")
           end)

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.name == "_smtp._tls" and
               record.content == "v=TLSRPTv1; rua=mailto:postmaster@#{zone.domain}"
           end)
  end

  test "service health reports managed record checks" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})
    assert {:ok, _config} = DNS.apply_zone_service(zone, "web")

    zone = DNS.get_zone(zone.id, user.id)
    web = Enum.find(DNS.zone_service_health(zone), &(&1.service == "web"))

    assert web.status in ["ok", "error"]
    assert Enum.any?(web.checks, &(&1.key == "web:www" and &1.status == "ok"))
  end

  test "applies managed turn records per zone" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain(), "default_ttl" => 600})

    assert {:ok, config} = DNS.apply_zone_service(zone, "turn")
    assert config.service == "turn"
    assert config.status == "ok"

    zone = DNS.get_zone(zone.id, user.id)
    [turn] = Enum.filter(zone.records, &(&1.service == "turn"))

    assert turn.managed == true
    assert turn.source == "system"
    assert turn.name == "turn"
    assert turn.type == "CNAME"
    assert turn.content == zone.domain
  end

  test "applies managed bluesky records per zone" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain(), "default_ttl" => 600})

    assert {:ok, config} = DNS.apply_zone_service(zone, "bluesky")
    assert config.service == "bluesky"
    assert config.status == "ok"

    zone = DNS.get_zone(zone.id, user.id)
    [bluesky] = Enum.filter(zone.records, &(&1.service == "bluesky"))

    assert bluesky.managed == true
    assert bluesky.source == "system"
    assert bluesky.name == "bsky"
    assert bluesky.type == "CNAME"
    assert bluesky.content == zone.domain
  end

  test "applies managed vpn records with optional api alias" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain(), "default_ttl" => 600})

    assert {:ok, config} =
             DNS.apply_zone_service(zone, "vpn", %{
               "settings" => %{
                 "vpn_host" => "vpn",
                 "vpn_target" => zone.domain,
                 "vpn_api_host" => "wg",
                 "vpn_api_target" => "api.#{zone.domain}"
               }
             })

    assert config.service == "vpn"
    assert config.status == "ok"

    zone = DNS.get_zone(zone.id, user.id)

    assert Enum.any?(zone.records, fn record ->
             record.service == "vpn" and record.name == "vpn" and record.type == "CNAME" and
               record.content == zone.domain
           end)

    assert Enum.any?(zone.records, fn record ->
             record.service == "vpn" and record.name == "wg" and record.type == "CNAME" and
               record.content == "api.#{zone.domain}"
           end)
  end

  defp unique_domain do
    "zone#{System.unique_integer([:positive])}.example.com"
  end
end
