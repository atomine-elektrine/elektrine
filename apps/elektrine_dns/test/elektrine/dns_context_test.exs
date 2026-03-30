defmodule Elektrine.DNSContextTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS

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

  defp unique_domain do
    "dnsctx#{System.unique_integer([:positive])}.example.com"
  end
end
