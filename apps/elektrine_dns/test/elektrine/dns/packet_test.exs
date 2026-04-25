defmodule Elektrine.DNS.PacketTest do
  use ExUnit.Case, async: true

  alias Elektrine.DNS.Packet

  test "clamps EDNS udp payload size from queries" do
    {:ok, query} =
      Packet.decode_query(
        Packet.encode_query(%{id: 1, rd: 1, qname: "example.com", qtype: :a, udp_size: 4096})
      )

    assert query.udp_size == 1232
  end

  test "truncates oversized udp responses" do
    response =
      Packet.encode_response(
        %{id: 1, rd: 1, qname: "example.com", qtype: :txt, udp_size: 512},
        [%{name: "example.com", type: :txt, content: String.duplicate("a", 600), ttl: 300}],
        :noerror,
        transport: :udp
      )

    assert byte_size(response) <= 512
    assert header(response).ancount == 0
    assert header(response).tc == 1
  end

  test "preserves fully-qualified host names on struct-backed records" do
    query = %{id: 1, rd: 0, qname: "elektrine.com", qtype: :ns, udp_size: 1232}

    response =
      Packet.encode_response(
        query,
        [
          %{
            __struct__: Elektrine.DNS.Record,
            host: "elektrine.com",
            name: "@",
            type: "NS",
            value: "ns1.elektrine.com",
            ttl: 300
          }
        ],
        :noerror,
        additional: [
          %{
            __struct__: Elektrine.DNS.Record,
            host: "ns1.elektrine.com",
            name: "ns1",
            type: "A",
            content: "66.42.127.87",
            ttl: 300
          }
        ]
      )

    assert {:ok, {:dns_rec, _header, _qd, answers, _ns, additional}} = :inet_dns.decode(response)
    assert Enum.map(answers, &record_domain/1) == ["elektrine.com"]
    assert Enum.map(additional, &record_domain/1) == ["ns1.elektrine.com"]
  end

  test "rejects query labels longer than the DNS limit" do
    label = String.duplicate("a", 64)

    packet =
      <<1::16, 0::16, 1::16, 0::16, 0::16, 0::16, byte_size(label)::8, label::binary, 0, 1::16,
        1::16>>

    assert {:error, :format_error} = Packet.decode_query(packet)
  end

  defp header(
         <<_id::16, flags::16, _qd::16, ancount::16, _nscount::16, _arcount::16, _rest::binary>>
       ) do
    %{ancount: ancount, tc: Bitwise.band(Bitwise.bsr(flags, 9), 1)}
  end

  defp record_domain(record), do: record |> elem(1) |> to_string() |> String.trim_trailing(".")
end
