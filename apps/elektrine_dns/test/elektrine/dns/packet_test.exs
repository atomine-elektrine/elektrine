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

  test "echoes an OPT record with the DO bit for EDNS queries" do
    {:ok, query} =
      Packet.decode_query(
        Packet.encode_query(%{
          id: 5,
          rd: 1,
          qname: "example.com",
          qtype: :a,
          udp_size: 1232,
          dnssec_ok: true
        })
      )

    assert query.edns

    response =
      Packet.encode_response(
        query,
        [%{name: "example.com", type: :a, content: "192.0.2.1", ttl: 60}],
        :noerror
      )

    assert header(response).arcount == 1

    assert <<0, 0, 41, _udp_size::16, 0, 0, opt_flags::16, 0, 0>> =
             :binary.part(response, byte_size(response) - 11, 11)

    assert Bitwise.band(opt_flags, 0x8000) != 0
  end

  test "omits the OPT record for plain queries" do
    packet =
      <<9::16, 0::16, 1::16, 0::16, 0::16, 0::16, 7, "example", 3, "com", 0, 1::16, 1::16>>

    {:ok, query} = Packet.decode_query(packet)
    refute query.edns

    response =
      Packet.encode_response(
        query,
        [%{name: "example.com", type: :a, content: "192.0.2.1", ttl: 60}],
        :noerror
      )

    assert header(response).arcount == 0
  end

  test "compresses answer owner names against the question name" do
    query = %{id: 7, rd: 0, qname: "www.example.com", qtype: :a, udp_size: 1232}

    response =
      Packet.encode_response(
        query,
        [%{name: "www.example.com", type: :a, content: "192.0.2.1", ttl: 60}],
        :noerror
      )

    # Owner emitted as a pointer to offset 12, followed by TYPE A / CLASS IN.
    assert :binary.match(response, <<0xC0, 0x0C, 0, 1, 0, 1>>) != :nomatch
    assert {:ok, {:dns_rec, _header, _qd, [answer], _ns, _ar}} = :inet_dns.decode(response)
    assert record_domain(answer) == "www.example.com"
  end

  test "rejects self-referencing compression pointers instead of looping" do
    packet = <<1::16, 0::16, 1::16, 0::16, 0::16, 0::16, 0xC0, 0x0C, 1::16, 1::16>>

    assert {:error, :format_error} = Packet.decode_query(packet)
  end

  test "never raises on arbitrary or mutated packets" do
    :rand.seed(:exsss, {101, 102, 103})

    for len <- 0..64, _repeat <- 1..4 do
      result = Packet.decode_query(:rand.bytes(len))
      assert match?({:ok, _}, result) or match?({:error, :format_error}, result)
    end

    valid =
      Packet.encode_query(%{id: 1, rd: 1, qname: "www.example.com", qtype: :a, udp_size: 1232})

    for _repeat <- 1..200 do
      position = :rand.uniform(byte_size(valid)) - 1
      <<before::binary-size(^position), _byte, rest::binary>> = valid
      mutated = <<before::binary, :rand.uniform(256) - 1, rest::binary>>

      result = Packet.decode_query(mutated)
      assert match?({:ok, _}, result) or match?({:error, :format_error}, result)
    end
  end

  defp header(
         <<_id::16, flags::16, _qd::16, ancount::16, _nscount::16, arcount::16, _rest::binary>>
       ) do
    %{ancount: ancount, arcount: arcount, tc: Bitwise.band(Bitwise.bsr(flags, 9), 1)}
  end

  defp record_domain(record), do: record |> elem(1) |> to_string() |> String.trim_trailing(".")
end
