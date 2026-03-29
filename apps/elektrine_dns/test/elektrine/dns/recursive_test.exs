defmodule Elektrine.DNS.TestRecursiveTransport do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{handler: nil, calls: []} end, name: __MODULE__)
  end

  def set_handler(fun), do: Agent.update(__MODULE__, &%{&1 | handler: fun, calls: []})
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def exchange_udp(ip, port, packet, timeout) do
    Agent.get_and_update(__MODULE__, fn %{handler: handler, calls: calls} = state ->
      {:ok, query} = Elektrine.DNS.Packet.decode_query(packet)
      result = handler.(ip, port, packet, timeout, query)
      {result, %{state | calls: [{ip, port, query.qname, query.qtype} | calls]}}
    end)
  end

  def exchange_tcp(ip, port, packet, timeout), do: exchange_udp(ip, port, packet, timeout)
end

defmodule Elektrine.DNS.RecursiveTest do
  use ExUnit.Case, async: false

  alias Elektrine.DNS.Packet
  alias Elektrine.DNS.Query

  setup_all do
    start_supervised!(Elektrine.DNS.TestRecursiveTransport)
    :ok
  end

  setup do
    old_dns = Application.get_env(:elektrine, :dns, [])

    Application.put_env(:elektrine, :dns,
      recursive_enabled: true,
      recursive_root_hints: [{{1, 1, 1, 1}, 53}, {{2, 2, 2, 2}, 53}],
      recursive_timeout: 100,
      recursive_transport: Elektrine.DNS.TestRecursiveTransport,
      recursive_allow_cidrs: ["127.0.0.0/8"]
    )

    clear_table(Elektrine.DNS.ZoneCache)
    clear_table(Elektrine.DNS.RecursiveCache)
    :persistent_term.erase({Elektrine.DNS.Recursive, :parsed_allow_cidrs})

    on_exit(fn ->
      Application.put_env(:elektrine, :dns, old_dns)
      clear_table(Elektrine.DNS.ZoneCache)
      clear_table(Elektrine.DNS.RecursiveCache)
      :persistent_term.erase({Elektrine.DNS.Recursive, :parsed_allow_cidrs})
    end)

    :ok
  end

  test "ignores invalid upstream responses and falls back to the next server" do
    Elektrine.DNS.TestRecursiveTransport.set_handler(fn ip, _port, _packet, _timeout, query ->
      answer = [%{name: query.qname, type: :a, content: "203.0.113.9", ttl: 300}]

      case ip do
        {1, 1, 1, 1} -> Packet.encode_response(%{query | id: query.id + 1}, answer, :noerror)
        {2, 2, 2, 2} -> Packet.encode_response(query, answer, :noerror)
      end
      |> then(&{:ok, &1})
    end)

    response =
      Query.answer(Packet.encode_query(%{id: 100, rd: 1, qname: "example.net", qtype: :a}),
        client_ip: {127, 0, 0, 1}
      )

    assert response =~ <<203, 0, 113, 9>>
    assert {{1, 1, 1, 1}, 53, "example.net", :a} in Elektrine.DNS.TestRecursiveTransport.calls()
    assert {{2, 2, 2, 2}, 53, "example.net", :a} in Elektrine.DNS.TestRecursiveTransport.calls()
  end

  test "ignores out-of-bailiwick glue and resolves the nameserver separately" do
    put_dns_config(recursive_root_hints: [{{1, 1, 1, 1}, 53}])

    Elektrine.DNS.TestRecursiveTransport.set_handler(fn ip, _port, _packet, _timeout, query ->
      response =
        case {ip, query.qname, query.qtype} do
          {{1, 1, 1, 1}, "example.test", :a} ->
            Packet.encode_response(
              query,
              [],
              :noerror,
              authority: [%{name: "example.test", type: :ns, value: "ns.bad.com", ttl: 300}],
              additional: [%{name: "ns.bad.com", type: :a, content: "203.0.113.53", ttl: 300}]
            )

          {{1, 1, 1, 1}, "ns.bad.com", :a} ->
            Packet.encode_response(
              query,
              [%{name: "ns.bad.com", type: :a, content: "198.51.100.53", ttl: 300}],
              :noerror
            )

          {{1, 1, 1, 1}, "ns.bad.com", :aaaa} ->
            Packet.encode_response(query, [], :noerror)

          {{198, 51, 100, 53}, "example.test", :a} ->
            Packet.encode_response(
              query,
              [%{name: "example.test", type: :a, content: "192.0.2.55", ttl: 300}],
              :noerror
            )
        end

      {:ok, response}
    end)

    response =
      Query.answer(Packet.encode_query(%{id: 101, rd: 1, qname: "example.test", qtype: :a}),
        client_ip: {127, 0, 0, 1}
      )

    assert response =~ <<192, 0, 2, 55>>

    assert Enum.any?(Elektrine.DNS.TestRecursiveTransport.calls(), fn {_ip, _port, qname, qtype} ->
             qname == "ns.bad.com" and qtype == :a
           end)
  end

  test "negative responses are cached using soa minimum ttl" do
    put_dns_config(recursive_root_hints: [{{1, 1, 1, 1}, 53}])

    Elektrine.DNS.TestRecursiveTransport.set_handler(fn _ip, _port, _packet, _timeout, query ->
      {:ok,
       Packet.encode_response(
         query,
         [],
         :nxdomain,
         authority: [
           %{
             name: "test",
             type: :soa,
             mname: "ns1.test",
             rname: "hostmaster.test",
             serial: 1,
             refresh: 3600,
             retry: 600,
             expire: 86400,
             minimum: 30,
             ttl: 120
           }
         ]
       )}
    end)

    packet = Packet.encode_query(%{id: 102, rd: 1, qname: "missing.test", qtype: :a})

    response1 = Query.answer(packet, client_ip: {127, 0, 0, 1})
    response2 = Query.answer(packet, client_ip: {127, 0, 0, 1})

    assert header(response1).rcode == 3
    assert header(response2).rcode == 3
    assert length(Elektrine.DNS.TestRecursiveTransport.calls()) == 1

    [{_, expires_at, _}] = :ets.lookup(Elektrine.DNS.RecursiveCache, {"missing.test", :a})
    ttl_ms = expires_at - System.monotonic_time(:millisecond)
    assert ttl_ms > 25_000
    assert ttl_ms <= 30_500
  end

  defp clear_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(table)
    end
  end

  defp header(<<_id::16, flags::16, _qd::16, _an::16, _ns::16, _ar::16, _rest::binary>>) do
    %{rcode: Bitwise.band(flags, 0x000F)}
  end

  defp put_dns_config(overrides) do
    current = Application.get_env(:elektrine, :dns, [])
    Application.put_env(:elektrine, :dns, Keyword.merge(current, overrides))
    :persistent_term.erase({Elektrine.DNS.Recursive, :parsed_allow_cidrs})
  end
end
