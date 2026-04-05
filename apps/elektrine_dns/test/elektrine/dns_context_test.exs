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

  defp unique_domain do
    "dnsctx#{System.unique_integer([:positive])}.example.com"
  end
end
