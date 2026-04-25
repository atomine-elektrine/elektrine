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
    old_dkim = Application.get_env(:elektrine, :managed_dns_dkim_module)
    old_master = Application.get_env(:elektrine, :encryption_master_secret)
    old_salt = Application.get_env(:elektrine, :encryption_key_salt)

    Application.put_env(:elektrine, :managed_dns_dkim_module, Elektrine.DNS.TestDKIM)
    Application.put_env(:elektrine, :encryption_master_secret, "test-master-secret-0123456789")
    Application.put_env(:elektrine, :encryption_key_salt, "test-key-salt-0123456789")

    on_exit(fn ->
      restore_env(:managed_dns_dkim_module, old_dkim)
      restore_env(:encryption_master_secret, old_master)
      restore_env(:encryption_key_salt, old_salt)
    end)

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
        "content" => "mx.external.example",
        "priority" => 10
      })

    assert {:ok, config} = DNS.apply_zone_service(zone, "mail")
    assert config.status == "conflict"
    assert config.last_error =~ "MX @ conflicts"

    zone = DNS.get_zone(zone.id, user.id)
    refute Enum.any?(zone.records, &(&1.service == "mail" and &1.managed))
  end

  test "rejects CNAME records that coexist with other record types" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, _record} =
             DNS.create_record(zone, %{
               "name" => "www",
               "type" => "A",
               "ttl" => 300,
               "content" => "203.0.113.10"
             })

    assert {:error, changeset} =
             DNS.create_record(zone, %{
               "name" => "www",
               "type" => "CNAME",
               "ttl" => 300,
               "content" => zone.domain
             })

    assert %{type: [_ | _]} = errors_on(changeset)
  end

  test "rejects invalid wildcard placement" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:error, changeset} =
             DNS.create_record(zone, %{
               "name" => "bad.*",
               "type" => "TXT",
               "ttl" => 300,
               "content" => "invalid"
             })

    assert %{name: [_ | _]} = errors_on(changeset)
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
        "content" => zone.domain,
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

  test "prefers a dedicated mail host when apex addresses exist" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, _apex} =
             DNS.create_record(zone, %{
               "name" => "@",
               "type" => "A",
               "ttl" => 300,
               "content" => "66.42.127.87"
             })

    assert {:ok, config} =
             DNS.apply_zone_service(zone, "mail")

    assert config.status == "ok"
    assert config.settings["mail_target"] == "mail.#{zone.domain}"

    zone = DNS.get_zone(zone.id, user.id)

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.managed_key == "mail:mx" and
               record.content == "mail.#{zone.domain}"
           end)

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.name == "mail" and record.type == "A" and
               record.content == "66.42.127.87"
           end)

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.name == "smtp" and record.type == "CNAME" and
               record.content == "mail.#{zone.domain}"
           end)
  end

  test "repairs legacy apex-target mail configs to the dedicated mail host" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, _apex} =
             DNS.create_record(zone, %{
               "name" => "@",
               "type" => "A",
               "ttl" => 300,
               "content" => "66.42.127.87"
             })

    assert {:ok, _config} =
             DNS.apply_zone_service(zone, "mail", %{
               "settings" => %{"mail_target" => zone.domain}
             })

    zone = DNS.get_zone(zone.id, user.id)

    assert {:ok, repaired} =
             DNS.apply_zone_service(zone, "mail", %{
               "settings" => %{"mail_target" => zone.domain}
             })

    assert repaired.settings["mail_target"] == "mail.#{zone.domain}"

    zone = DNS.get_zone(zone.id, user.id)

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.managed_key == "mail:mx" and
               record.content == "mail.#{zone.domain}"
           end)
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
    refute config.settings["dkim_private_key"] == "PRIVATEKEY"
    assert String.contains?(config.settings["dkim_value"], "v=DKIM1")
    assert config.settings["caa_issue"] == "letsencrypt.org"
    assert config.settings["mail_target"] == zone.domain

    zone = DNS.get_zone(zone.id, user.id)

    mail_health = DNS.zone_service_health(zone) |> Enum.find(&(&1.service == "mail"))
    assert mail_health.settings["dkim_private_key"] == "[redacted]"

    assert Enum.any?(
             zone.records,
             &(&1.service == "mail" and &1.managed_key == "mail:mx" and &1.content == zone.domain)
           )

    assert Enum.any?(zone.records, &(&1.service == "mail" and &1.managed_key == "mail:dkim"))

    assert Enum.any?(
             zone.records,
             &(&1.service == "mail" and &1.managed_key == "mail:mta-sts-txt")
           )

    assert Enum.any?(zone.records, &(&1.service == "mail" and &1.managed_key == "mail:tls-rpt"))

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.managed_key == "mail:caa:issue" and
               record.type == "CAA" and record.tag == "issue" and
               record.content == "letsencrypt.org"
           end)

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.name == "_mta-sts" and
               String.starts_with?(record.content, "v=STSv1; id=")
           end)

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.name == "_smtp._tls" and
               record.content == "v=TLSRPTv1; rua=mailto:postmaster@#{zone.domain}"
           end)
  end

  test "managed mail service generates TLSA records when association data is configured" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, config} =
             DNS.apply_zone_service(zone, "mail", %{
               "settings" => %{
                 "tlsa_association_data" => "aabbccdd",
                 "tlsa_usage" => "3",
                 "tlsa_selector" => "0",
                 "tlsa_matching_type" => "1"
               }
             })

    assert config.status == "ok"
    assert config.settings["tlsa_association_data"] == "aabbccdd"

    zone = DNS.get_zone(zone.id, user.id)

    assert Enum.any?(zone.records, fn record ->
             record.service == "mail" and record.managed_key == "mail:tlsa" and
               record.name == "_25._tcp" and record.type == "TLSA" and
               record.content == "AABBCCDD" and record.usage == 3 and record.selector == 0 and
               record.matching_type == 1
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

  defp restore_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_env(key, value), do: Application.put_env(:elektrine, key, value)
end
