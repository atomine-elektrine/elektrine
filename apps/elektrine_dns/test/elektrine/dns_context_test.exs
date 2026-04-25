defmodule Elektrine.DNS.ScanResolver do
  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
  end

  def lookup(domain, :in, type, opts) do
    timeout = Keyword.get(opts, :timeout)

    Agent.get(__MODULE__, fn responses ->
      Map.get(responses, {List.to_string(domain), type, timeout}, [])
    end)
  end
end

defmodule Elektrine.DNSContextTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS
  alias Elektrine.Repo

  setup_all do
    start_supervised!(Elektrine.DNS.ScanResolver)
    :ok
  end

  setup do
    old_dns = Application.get_env(:elektrine, :dns, [])

    Application.put_env(
      :elektrine,
      :dns,
      Keyword.merge(old_dns,
        nameservers: ["ns1.elektrine.com", "ns2.elektrine.com"],
        dns_resolver: Elektrine.DNS.ScanResolver
      )
    )

    Agent.update(Elektrine.DNS.ScanResolver, fn _ -> %{} end)

    on_exit(fn ->
      Application.put_env(:elektrine, :dns, old_dns)
      Agent.update(Elektrine.DNS.ScanResolver, fn _ -> %{} end)
    end)

    :ok
  end

  test "list_user_zones/1 provisions the built-in user subdomain zone" do
    user = AccountsFixtures.user_fixture()

    [zone] = DNS.list_user_zones(user)

    assert zone.domain == DNS.builtin_user_zone_domain(user)
    assert zone.status == "verified"
    assert DNS.builtin_user_zone?(zone, user)

    assert Enum.any?(zone.records, fn record ->
             record.name == "@" and record.type == "ALIAS" and record.managed and record.required
           end)
  end

  test "built-in user zone keeps apex routing reserved" do
    user = AccountsFixtures.user_fixture()
    [zone] = DNS.list_user_zones(user)

    assert {:error, changeset} =
             DNS.create_record(zone, %{
               "name" => "@",
               "type" => "A",
               "ttl" => 300,
               "content" => "198.51.100.10"
             })

    assert "the apex host is reserved for Elektrine profile routing; only TXT and CAA are allowed there" in errors_on(
             changeset
           ).name

    assert {:ok, record} =
             DNS.create_record(zone, %{
               "name" => "blog",
               "type" => "A",
               "ttl" => 300,
               "content" => "198.51.100.11"
             })

    assert record.name == "blog"

    assert {:ok, txt_record} =
             DNS.create_record(zone, %{
               "name" => "@",
               "type" => "TXT",
               "ttl" => 300,
               "content" => "hello=world"
             })

    assert txt_record.name == "@"
    assert txt_record.type == "TXT"
  end

  test "built-in user zone cannot be deleted" do
    user = AccountsFixtures.user_fixture()
    [zone] = DNS.list_user_zones(user)

    assert {:error, changeset} = DNS.delete_zone(zone)

    assert "is the built-in profile subdomain and cannot be deleted" in errors_on(changeset).domain
  end

  test "built-in user zone can be handed off to external dns for apex A records" do
    user = AccountsFixtures.user_fixture()
    [zone] = DNS.list_user_zones(user)

    assert {:ok, updated_user} = DNS.update_builtin_user_zone_mode(user, "external_dns")
    zone = DNS.get_zone(zone.id, updated_user.id)

    refute Enum.any?(zone.records, &(&1.managed_key == "system:profile-apex"))

    assert {:ok, record} =
             DNS.create_record(zone, %{
               "name" => "@",
               "type" => "A",
               "ttl" => 300,
               "content" => "198.51.100.77"
             })

    assert record.name == "@"
    assert record.type == "A"
  end

  test "switching built-in user zone back to platform hosting requires apex cleanup" do
    user = AccountsFixtures.user_fixture()
    [zone] = DNS.list_user_zones(user)

    {:ok, updated_user} = DNS.update_builtin_user_zone_mode(user, "external_dns")
    zone = DNS.get_zone(zone.id, updated_user.id)

    {:ok, _record} =
      DNS.create_record(zone, %{
        "name" => "@",
        "type" => "A",
        "ttl" => 300,
        "content" => "198.51.100.88"
      })

    assert {:error, changeset} = DNS.update_builtin_user_zone_mode(updated_user, "platform")

    assert "cannot switch back to platform hosting until apex records are removed: @ A" in errors_on(
             changeset
           ).built_in_subdomain_mode

    refetched_user = Repo.get!(Elektrine.Accounts.User, updated_user.id)
    assert refetched_user.built_in_subdomain_mode == "external_dns"
  end

  test "normalizes absolute in-zone record names on create and update" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, record} =
             DNS.create_record(zone, %{
               "name" => zone.domain,
               "type" => "A",
               "ttl" => 300,
               "content" => "198.51.100.10"
             })

    assert record.name == "@"

    assert {:ok, updated} =
             DNS.update_record(record, %{
               "name" => "ns1.#{zone.domain}",
               "type" => "A",
               "ttl" => 300,
               "content" => "198.51.100.11"
             })

    assert updated.name == "ns1"
  end

  test "normalizes escaped apex names on create" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, record} =
             DNS.create_record(zone, %{
               "name" => "\\@",
               "type" => "A",
               "ttl" => 300,
               "content" => "198.51.100.10"
             })

    assert record.name == "@"
  end

  test "stores private record visibility in metadata" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, record} =
             DNS.create_record(zone, %{
               "name" => "admin",
               "type" => "A",
               "ttl" => 300,
               "content" => "100.90.10.120",
               "private" => "true"
             })

    assert Elektrine.DNS.Record.private?(record)
    assert record.metadata["visibility"] == "private"

    assert {:ok, updated} = DNS.update_record(record, %{"private" => "false"})

    refute Elektrine.DNS.Record.private?(updated)
    refute Map.has_key?(updated.metadata, "visibility")
  end

  test "rejects apex cname records" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:error, changeset} =
             DNS.create_record(zone, %{
               "name" => zone.domain,
               "type" => "CNAME",
               "ttl" => 300,
               "content" => "edge.elektrine.com"
             })

    assert "cannot be used at the zone apex" in errors_on(changeset).type
  end

  test "accepts apex alias records and normalizes the target hostname" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, record} =
             DNS.create_record(zone, %{
               "name" => zone.domain,
               "type" => "ALIAS",
               "ttl" => 300,
               "content" => "Edge.Elektrine.com."
             })

    assert record.name == "@"
    assert record.content == "edge.elektrine.com"
  end

  test "supported record types include https svcb and sshfp" do
    assert "HTTPS" in DNS.supported_record_types()
    assert "SVCB" in DNS.supported_record_types()
    assert "SSHFP" in DNS.supported_record_types()
  end

  test "accepts sshfp records" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, record} =
             DNS.create_record(zone, %{
               "name" => "host",
               "type" => "SSHFP",
               "ttl" => 300,
               "algorithm" => 4,
               "digest_type" => 2,
               "content" => "1234567890abcdef"
             })

    assert record.type == "SSHFP"
    assert record.content == "1234567890ABCDEF"
  end

  test "accepts https and svcb records with service binding params" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, https_record} =
             DNS.create_record(zone, %{
               "name" => "@",
               "type" => "HTTPS",
               "ttl" => 300,
               "priority" => 1,
               "content" => "Svc.Example.net. alpn=h2,h3 port=443"
             })

    assert https_record.content == "svc.example.net alpn=h2,h3 port=443"

    assert {:ok, svcb_record} =
             DNS.create_record(zone, %{
               "name" => "_svc",
               "type" => "SVCB",
               "ttl" => 300,
               "priority" => 2,
               "content" => ". no-default-alpn"
             })

    assert svcb_record.content == ". no-default-alpn"
  end

  test "scan_existing_zone returns observed delegation and common records" do
    put_lookup("scanme.com", :ns, 5_000, [~c"ns1.cloudflare.com", ~c"ns2.cloudflare.com"])
    put_lookup("scanme.com", :a, 3_000, [{198, 51, 100, 10}])
    put_lookup("scanme.com", :mx, 3_000, [{10, ~c"mail.scanme.com"}])
    put_lookup("www.scanme.com", :cname, 3_000, [~c"proxy.other.net"])

    scan = DNS.scan_existing_zone("scanme.com")

    assert scan.domain == "scanme.com"
    assert scan.provider_hint == "Cloudflare"
    refute scan.delegated_to_elektrine
    assert scan.nameservers == ["ns1.cloudflare.com", "ns2.cloudflare.com"]
    assert %{host: "@", type: "A", values: ["198.51.100.10"]} in scan.records
    assert %{host: "@", type: "MX", values: ["10 mail.scanme.com"]} in scan.records
    assert %{host: "www", type: "CNAME", values: ["proxy.other.net"]} in scan.records
  end

  test "scan_existing_zone ignores incomplete hostnames" do
    assert DNS.scan_existing_zone("e") == nil
    assert DNS.scan_existing_zone("localhost") == nil
  end

  test "rejects non-apex alias records" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:error, changeset} =
             DNS.create_record(zone, %{
               "name" => "www",
               "type" => "ALIAS",
               "ttl" => 300,
               "content" => "edge.elektrine.com"
             })

    assert "can only be used at the zone apex" in errors_on(changeset).type
  end

  test "rejects invalid A and AAAA record content" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:error, changeset} =
             DNS.create_record(zone, %{
               "name" => "www",
               "type" => "A",
               "ttl" => 300,
               "content" => "not-an-ip"
             })

    assert "must be a valid IPv4 address" in errors_on(changeset).content

    assert {:error, changeset} =
             DNS.create_record(zone, %{
               "name" => "www",
               "type" => "AAAA",
               "ttl" => 300,
               "content" => "203.0.113.10"
             })

    assert "must be a valid IPv6 address" in errors_on(changeset).content
  end

  test "record writes bump the zone serial and publication timestamp" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert {:ok, record} =
             DNS.create_record(zone, %{
               "name" => "www",
               "type" => "A",
               "ttl" => 300,
               "content" => "203.0.113.10"
             })

    zone_after_create = DNS.get_zone(zone.id, user.id)
    assert zone_after_create.serial == zone.serial + 1
    assert zone_after_create.last_published_at

    assert {:ok, _record} = DNS.update_record(record, %{"content" => "203.0.113.11"})

    zone_after_update = DNS.get_zone(zone.id, user.id)
    assert zone_after_update.serial == zone_after_create.serial + 1
  end

  test "domain_health/1 reports missing mail security records" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    health = DNS.domain_health(DNS.get_zone(zone.id, user.id))

    assert health.status == :missing
    assert health.score < 50
    assert Enum.any?(health.checks, &(&1.label == "MX records" and &1.status == :missing))
    assert Enum.any?(health.checks, &(&1.label == "SPF policy" and &1.status == :missing))
    assert Enum.any?(health.recommendations, &(&1.label == "DMARC policy"))
  end

  test "domain_health/1 recognizes common domain hardening records" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    {:ok, _} =
      DNS.create_record(zone, %{
        "name" => "@",
        "type" => "MX",
        "ttl" => 300,
        "priority" => 10,
        "content" => "mail.#{zone.domain}"
      })

    {:ok, _} =
      DNS.create_record(zone, %{
        "name" => "@",
        "type" => "TXT",
        "ttl" => 300,
        "content" => "v=spf1 mx -all"
      })

    {:ok, _} =
      DNS.create_record(zone, %{
        "name" => "default._domainkey",
        "type" => "TXT",
        "ttl" => 300,
        "content" => "v=DKIM1; k=rsa; p=abc123"
      })

    {:ok, _} =
      DNS.create_record(zone, %{
        "name" => "_dmarc",
        "type" => "TXT",
        "ttl" => 300,
        "content" => "v=DMARC1; p=reject; rua=mailto:postmaster@#{zone.domain}"
      })

    {:ok, _} =
      DNS.create_record(zone, %{
        "name" => "@",
        "type" => "CAA",
        "ttl" => 300,
        "flags" => 0,
        "tag" => "issue",
        "content" => "letsencrypt.org"
      })

    {:ok, _} =
      DNS.create_record(zone, %{
        "name" => "_smtp._tls",
        "type" => "TXT",
        "ttl" => 300,
        "content" => "v=TLSRPTv1; rua=mailto:postmaster@#{zone.domain}"
      })

    health = DNS.domain_health(DNS.get_zone(zone.id, user.id))

    assert Enum.find(health.checks, &(&1.label == "MX records")).status == :ok
    assert Enum.find(health.checks, &(&1.label == "SPF policy")).status == :ok
    assert Enum.find(health.checks, &(&1.label == "DKIM key")).status == :ok
    assert Enum.find(health.checks, &(&1.label == "DMARC policy")).status == :ok
    assert Enum.find(health.checks, &(&1.label == "CAA records")).status == :ok
    assert Enum.find(health.checks, &(&1.label == "SMTP TLS reports")).status == :ok
    assert health.score >= 50
  end

  defp unique_domain do
    "dnsctx#{System.unique_integer([:positive])}.example.com"
  end

  defp put_lookup(domain, type, timeout, result) do
    Agent.update(Elektrine.DNS.ScanResolver, &Map.put(&1, {domain, type, timeout}, result))
  end
end
