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

  defp header(
         <<_id::16, flags::16, _qd::16, ancount::16, _nscount::16, _arcount::16, _rest::binary>>
       ) do
    %{ancount: ancount, tc: Bitwise.band(Bitwise.bsr(flags, 9), 1)}
  end
end
