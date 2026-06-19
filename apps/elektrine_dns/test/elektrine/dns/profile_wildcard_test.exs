defmodule Elektrine.DNS.ProfileWildcardTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS
  alias Elektrine.DNS.Record

  setup do
    previous_dns_config = Application.get_env(:elektrine, :dns, [])
    previous_profile_base_domains = Application.get_env(:elektrine, :profile_base_domains)

    domain = "wc#{System.unique_integer([:positive])}.com"

    Application.put_env(:elektrine, :profile_base_domains, [domain])

    Application.put_env(
      :elektrine,
      :dns,
      Keyword.merge(previous_dns_config,
        edge_proxy_ipv4_addresses: ["198.51.100.10"],
        edge_proxy_ipv6_addresses: ["2001:db8::10"]
      )
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :dns, previous_dns_config)

      if previous_profile_base_domains do
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_base_domains)
      else
        Application.delete_env(:elektrine, :profile_base_domains)
      end
    end)

    {:ok, domain: domain}
  end

  defp wildcard_record(zone_id, type) do
    zone_id
    |> DNS.list_zone_records()
    |> Enum.find(fn record -> record.name == "*" and record.type == type end)
  end

  test "creates a proxied wildcard A/AAAA catch-all in the profile base-domain zone", %{
    domain: domain
  } do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => domain})

    assert {^domain, :ok} =
             DNS.ensure_profile_subdomain_wildcards()
             |> Enum.find(fn {d, _result} -> d == domain end)

    a_record = wildcard_record(zone.id, "A")
    assert a_record
    assert a_record.managed
    assert Record.proxied?(a_record)

    aaaa_record = wildcard_record(zone.id, "AAAA")
    assert aaaa_record
    assert Record.proxied?(aaaa_record)
  end

  test "is idempotent", %{domain: domain} do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => domain})

    DNS.ensure_profile_subdomain_wildcards()
    DNS.ensure_profile_subdomain_wildcards()

    matches =
      zone.id
      |> DNS.list_zone_records()
      |> Enum.filter(fn record -> record.name == "*" and record.type == "A" end)

    assert length(matches) == 1
  end

  test "reports zone_not_found when the base domain is not a managed zone", %{domain: domain} do
    assert {^domain, {:error, :zone_not_found}} =
             DNS.ensure_profile_subdomain_wildcards()
             |> Enum.find(fn {d, _result} -> d == domain end)
  end
end
