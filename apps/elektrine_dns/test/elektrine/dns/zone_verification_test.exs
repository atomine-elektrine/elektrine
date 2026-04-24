defmodule Elektrine.DNS.TestResolver do
  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
  end

  def lookup(domain, :in, :ns, timeout: 5_000) do
    Agent.get(__MODULE__, fn responses ->
      Map.fetch!(responses, {List.to_string(domain), 5_000})
    end)
  end

  def lookup(domain, :in, type, timeout: 5_000) when type in [:a, :aaaa] do
    Agent.get(__MODULE__, fn responses ->
      Map.get(responses, {List.to_string(domain), type, 5_000}, [])
    end)
  end
end

defmodule Elektrine.DNS.TestVerificationTransport do
  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
  end

  def exchange_udp(ip, port, _packet, _timeout) do
    Agent.get(__MODULE__, fn responses ->
      Map.get(responses, {ip, port}, {:error, :timeout})
    end)
  end

  def exchange_tcp(ip, port, packet, timeout), do: exchange_udp(ip, port, packet, timeout)
end

defmodule Elektrine.DNS.ZoneVerificationTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS

  setup_all do
    start_supervised!(Elektrine.DNS.TestResolver)
    start_supervised!(Elektrine.DNS.TestVerificationTransport)
    :ok
  end

  setup do
    old_dns = Application.get_env(:elektrine, :dns, [])

    Application.put_env(
      :elektrine,
      :dns,
      Keyword.merge(old_dns,
        nameservers: ["ns1.elektrine.com", "ns2.elektrine.com"],
        dns_resolver: Elektrine.DNS.TestResolver,
        recursive_transport: Elektrine.DNS.TestVerificationTransport,
        recursive_timeout: 100
      )
    )

    Agent.update(Elektrine.DNS.TestResolver, fn _ -> %{} end)
    Agent.update(Elektrine.DNS.TestVerificationTransport, fn _ -> %{} end)

    on_exit(fn ->
      Application.put_env(:elektrine, :dns, old_dns)
      Agent.update(Elektrine.DNS.TestResolver, fn _ -> %{} end)
      Agent.update(Elektrine.DNS.TestVerificationTransport, fn _ -> %{} end)
    end)

    :ok
  end

  test "verify_zone stores specific delegation mismatch details" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_lookup(zone.domain, [~c"ns1.wrong.test"])

    assert {:ok, updated} = DNS.verify_zone(zone)
    assert updated.status == "pending"

    assert updated.last_error ==
             "Delegation mismatch for the configured nameservers. Expected: ns1.elektrine.com, ns2.elektrine.com. Observed: ns1.wrong.test."
  end

  test "verify_zone reports when no nameservers are observed" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_lookup(zone.domain, [])

    assert {:ok, updated} = DNS.verify_zone(zone)

    assert updated.last_error ==
             "Delegation mismatch for the configured nameservers. Expected: ns1.elektrine.com, ns2.elektrine.com. Observed: none."
  end

  test "verify_zone marks the zone verified when delegation matches" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_lookup(zone.domain, [~c"ns2.elektrine.com", ~c"ns1.elektrine.com"])
    put_nameserver_ip("ns1.elektrine.com", {203, 0, 113, 10})
    put_authoritative_response({203, 0, 113, 10}, authoritative_soa_response(zone.domain))

    assert {:ok, updated} = DNS.verify_zone(zone)
    assert updated.status == "verified"
    assert updated.last_error == nil
  end

  test "verify_zone reports when delegated nameservers are not serving an authoritative soa" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_lookup(zone.domain, [~c"ns1.elektrine.com", ~c"ns2.elektrine.com"])
    put_nameserver_ip("ns1.elektrine.com", {203, 0, 113, 10})

    put_authoritative_response(
      {203, 0, 113, 10},
      Elektrine.DNS.Packet.encode_response(
        %{id: 1, rd: 0, qname: zone.domain, qtype: :soa},
        [],
        :noerror
      )
    )

    assert {:ok, updated} = DNS.verify_zone(zone)
    assert updated.status == "pending"

    assert updated.last_error ==
             "Delegation matches the configured nameservers, but they are not serving an authoritative SOA for #{zone.domain}: received a non-authoritative or empty SOA response"
  end

  defp put_lookup(domain, result) do
    Agent.update(Elektrine.DNS.TestResolver, &Map.put(&1, {domain, 5_000}, result))
  end

  defp put_nameserver_ip(nameserver, ip) do
    Agent.update(Elektrine.DNS.TestResolver, &Map.put(&1, {nameserver, :a, 5_000}, [ip]))
  end

  defp put_authoritative_response(ip, response) do
    Agent.update(Elektrine.DNS.TestVerificationTransport, &Map.put(&1, {ip, 53}, {:ok, response}))
  end

  defp authoritative_soa_response(domain) do
    Elektrine.DNS.Packet.encode_response(
      %{id: 1, rd: 0, qname: domain, qtype: :soa},
      [
        %{
          name: domain,
          type: :soa,
          mname: "ns1.elektrine.com",
          rname: "hostmaster.elektrine.com",
          serial: 1,
          refresh: 3600,
          retry: 600,
          expire: 1_209_600,
          minimum: 300,
          ttl: 300
        }
      ],
      :noerror,
      authoritative: true
    )
  end

  defp unique_domain do
    "verify#{System.unique_integer([:positive])}.elektrine.io"
  end
end
