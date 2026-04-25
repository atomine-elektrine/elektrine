defmodule Elektrine.DNS.QueryStatsBufferTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS
  alias Elektrine.DNS.QueryStat
  alias Elektrine.Repo

  test "buffers and aggregates repeated query stats" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    result = %{
      zone: zone,
      authoritative: true,
      qname: "www.#{zone.domain}",
      qtype: :a,
      rcode: :noerror
    }

    DNS.track_query(result, "udp")
    DNS.track_query(result, "udp")
    Elektrine.DNS.QueryStatsBuffer.flush()

    stat = Repo.one!(QueryStat)

    assert stat.qname == "www.#{zone.domain}"
    assert stat.qtype == "A"
    assert stat.rcode == "NOERROR"
    assert stat.transport == "udp"
    assert stat.query_count == 2
  end

  test "collapses deep random labels for metrics cardinality" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    result = %{
      zone: zone,
      authoritative: true,
      qname: "random.user.bsky.#{zone.domain}",
      qtype: :a,
      rcode: :nxdomain
    }

    DNS.track_query(result, "udp")
    Elektrine.DNS.QueryStatsBuffer.flush()

    stat = Repo.one!(QueryStat)

    assert stat.qname == "*.user.bsky.#{zone.domain}"
    assert stat.rcode == "NXDOMAIN"
  end

  defp unique_domain do
    "zone#{System.unique_integer([:positive])}.example.com"
  end
end
