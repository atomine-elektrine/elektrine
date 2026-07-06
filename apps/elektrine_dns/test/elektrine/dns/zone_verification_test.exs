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

  def exchange_udp(ip, port, packet, _timeout) do
    {:ok, query} = Elektrine.DNS.Packet.decode_query(packet)

    Agent.get(__MODULE__, fn responses ->
      Map.get(
        responses,
        {ip, port, query.qname, query.qtype},
        Map.get(responses, {ip, port, :any, query.qtype}, {:error, :timeout})
      )
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
        nameserver_assignment_secret: "zone-verification-test-secret",
        dns_resolver: Elektrine.DNS.TestResolver,
        recursive_transport: Elektrine.DNS.TestVerificationTransport,
        recursive_timeout: 100,
        recursive_root_hints: [{{192, 0, 2, 1}, 53}]
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

    put_tld_delegation(zone.domain, ["ns1.wrong.test"], [{{203, 0, 113, 53}, 53}])

    assert {:ok, updated} = DNS.verify_zone(zone)
    assert updated.status == "pending"

    expected = DNS.assigned_nameservers(zone) |> Enum.sort() |> Enum.join(", ")

    assert updated.last_error ==
             "Delegation mismatch for the configured nameservers. Expected: #{expected}. Observed: ns1.wrong.test."
  end

  test "verify_zone reports when no nameservers are observed" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_tld_delegation(zone.domain, [], [])

    assert {:ok, updated} = DNS.verify_zone(zone)

    expected = DNS.assigned_nameservers(zone) |> Enum.sort() |> Enum.join(", ")

    assert updated.last_error ==
             "Delegation mismatch for the configured nameservers. Expected: #{expected}. Observed: none."
  end

  test "verify_zone marks the zone verified when delegation matches" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_tld_delegation(zone.domain, Enum.reverse(DNS.assigned_nameservers(zone)), [
      {{203, 0, 113, 10}, 53}
    ])

    assert {:ok, updated} = DNS.verify_zone(zone)
    assert updated.status == "verified"
    assert updated.last_error == nil
  end

  test "verify_zone rejects delegation to the base nameservers without the assigned set" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_tld_delegation(zone.domain, DNS.nameservers(), [
      {{203, 0, 113, 10}, 53}
    ])

    assert {:ok, updated} = DNS.verify_zone(zone)
    assert updated.status == "pending"
    assert updated.last_error =~ "Delegation mismatch for the configured nameservers."
    assert updated.last_error =~ List.first(DNS.assigned_nameservers(zone))
    assert updated.last_error =~ "Observed: ns1.elektrine.com, ns2.elektrine.com."
  end

  defp put_tld_delegation(domain, nameservers, endpoints) do
    tld = domain |> String.split(".") |> List.last()
    tld_server = {192, 0, 2, 53}

    put_response(
      {192, 0, 2, 1},
      tld,
      :ns,
      delegated_nameserver_response(tld, ["ns1.#{tld_server_name()}"], [tld_server])
    )

    put_response(
      tld_server,
      domain,
      :ns,
      delegated_nameserver_response(domain, nameservers, endpoints)
    )
  end

  defp put_response(ip, qname, qtype, response, opts \\ []) do
    Agent.update(Elektrine.DNS.TestVerificationTransport, fn state ->
      case Keyword.get(opts, :match_any_qname?, false) do
        true ->
          Map.put(state, {ip, 53, :any, qtype}, {:ok, response})

        false ->
          Map.put(state, {ip, 53, qname, qtype}, {:ok, response})
      end
    end)
  end

  defp delegated_nameserver_response(domain, nameservers, endpoints) do
    additional =
      Enum.zip(nameservers, endpoints)
      |> Enum.flat_map(fn {nameserver, endpoint} ->
        ip =
          case endpoint do
            {tuple, _port} when is_tuple(tuple) -> tuple
            tuple when is_tuple(tuple) -> tuple
          end

        case ip do
          {_, _, _, _} ->
            [%{name: nameserver, type: :a, content: :inet.ntoa(ip) |> to_string(), ttl: 300}]

          tuple when tuple_size(tuple) == 8 ->
            [
              %{
                name: nameserver,
                type: :aaaa,
                content: :inet.ntoa(tuple) |> to_string(),
                ttl: 300
              }
            ]
        end
      end)

    Elektrine.DNS.Packet.encode_response(
      %{id: 1, rd: 0, qname: domain, qtype: :ns},
      Enum.map(nameservers, fn nameserver ->
        %{name: domain, type: :ns, value: nameserver, ttl: 300}
      end),
      :noerror,
      authoritative: true,
      additional: additional
    )
  end

  defp tld_server_name, do: "gtld.test"

  defp unique_domain do
    "verify#{System.unique_integer([:positive])}.elektrine.io"
  end
end
