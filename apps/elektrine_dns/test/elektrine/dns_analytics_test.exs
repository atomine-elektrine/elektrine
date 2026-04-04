defmodule Elektrine.DNSAnalyticsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS

  test "rolls up authoritative query analytics per zone" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert :ok =
             DNS.track_query(
               %{
                 zone: zone,
                 authoritative: true,
                 qname: zone.domain,
                 qtype: :mx,
                 rcode: :noerror
               },
               "udp"
             )

    assert :ok =
             DNS.track_query(
               %{
                 zone: zone,
                 authoritative: true,
                 qname: zone.domain,
                 qtype: :mx,
                 rcode: :noerror
               },
               "udp"
             )

    assert :ok =
             DNS.track_query(
               %{
                 zone: zone,
                 authoritative: true,
                 qname: "missing.#{zone.domain}",
                 qtype: :a,
                 rcode: :nxdomain
               },
               "tcp"
             )

    assert %{total_queries: 3, queries_today: 3, queries_this_week: 3, nxdomain_queries: 1} =
             DNS.get_zone_query_stats(zone.id)

    assert [%{qtype: "MX", count: 2}, %{qtype: "A", count: 1}] =
             DNS.get_zone_query_type_breakdown(zone.id, 10)

    zone_domain = zone.domain
    assert [%{qname: ^zone_domain, count: 2} | _] = DNS.get_zone_top_names(zone.id, 10)

    assert Enum.any?(
             DNS.get_zone_rcode_breakdown(zone.id),
             &(&1.rcode == "NXDOMAIN" and &1.count == 1)
           )

    assert Enum.any?(
             DNS.get_zone_daily_query_counts(zone.id, 30),
             &(&1.date == Date.utc_today() and &1.count == 3)
           )
  end

  test "ignores non-authoritative query results" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    assert :ok =
             DNS.track_query(
               %{
                 zone: zone,
                 authoritative: false,
                 qname: zone.domain,
                 qtype: :a,
                 rcode: :noerror
               },
               "udp"
             )

    assert %{total_queries: 0, queries_today: 0, queries_this_week: 0, nxdomain_queries: 0} =
             DNS.get_zone_query_stats(zone.id)
  end

  defp unique_domain do
    "dnsanalytics#{System.unique_integer([:positive])}.example.com"
  end
end
