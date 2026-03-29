defmodule Elektrine.DNS.QueryTest do
  use ExUnit.Case, async: true

  alias Elektrine.DNS.Query
  alias Elektrine.DNS.Zone
  alias Elektrine.DNS.Record

  setup do
    zone = %Zone{
      domain: "example.com",
      records: [
        %Record{name: "@", type: "A", content: "203.0.113.10", ttl: 300},
        %Record{name: "www", type: "A", content: "203.0.113.20", ttl: 300},
        %Record{name: "wild", type: "TXT", content: "hello", ttl: 300},
        %Record{name: "*", type: "A", content: "203.0.113.30", ttl: 300},
        %Record{name: "alias", type: "CNAME", content: "www.example.com", ttl: 300},
        %Record{name: "mail", type: "MX", content: "mx.example.com", ttl: 300, priority: 10},
        %Record{name: "mx", type: "A", content: "203.0.113.40", ttl: 300},
        %Record{
          name: "@",
          type: "DNSKEY",
          content: "AQAB",
          ttl: 300,
          flags: 257,
          protocol: 3,
          algorithm: 13
        },
        %Record{
          name: "delegated",
          type: "DS",
          content: "A1B2C3D4",
          ttl: 300,
          key_tag: 12345,
          algorithm: 13,
          digest_type: 2
        },
        %Record{
          name: "_25._tcp.mail",
          type: "TLSA",
          content: "AABBCCDD",
          ttl: 300,
          usage: 3,
          selector: 1,
          matching_type: 1
        }
      ]
    }

    table = :ets.whereis(Elektrine.DNS.ZoneCache)

    if table == :undefined do
      :ets.new(Elektrine.DNS.ZoneCache, [:named_table, :public])
    else
      :ets.delete_all_objects(Elektrine.DNS.ZoneCache)
    end

    :ets.insert(Elektrine.DNS.ZoneCache, {"example.com", zone})
    :ok
  end

  test "answers exact A queries" do
    response = Query.answer(build_query("www.example.com", 1))
    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert response =~ <<203, 0, 113, 20>>
  end

  test "returns noerror with zero answers for existing name with different type" do
    response = Query.answer(build_query("alias.example.com", 1))
    assert header(response).ancount == 0
    assert header(response).rcode == 0
  end

  test "returns nxdomain for unknown names" do
    response = Query.answer(build_query("missing.example.com", 16))
    assert header(response).rcode == 3
    assert header(response).nscount == 1
  end

  test "uses wildcard records when no exact name exists" do
    response = Query.answer(build_query("foo.example.com", 1))
    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert response =~ <<203, 0, 113, 30>>
  end

  test "returns additional A records for MX targets" do
    response = Query.answer(build_query("mail.example.com", 15))
    assert header(response).ancount == 1
    assert header(response).arcount == 1
    assert response =~ <<203, 0, 113, 40>>
  end

  test "answers DNSKEY queries" do
    response = Query.answer(build_query("example.com", 48))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert response =~ <<1, 1, 3, 13, 1, 0, 1>>
  end

  test "answers DS queries" do
    response = Query.answer(build_query("delegated.example.com", 43))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert response =~ <<0x30, 0x39, 13, 2, 0xA1, 0xB2, 0xC3, 0xD4>>
  end

  test "answers TLSA queries" do
    response = Query.answer(build_query("_25._tcp.mail.example.com", 52))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert response =~ <<3, 1, 1, 0xAA, 0xBB, 0xCC, 0xDD>>
  end

  defp build_query(name, type) do
    <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      encode_name(name)::binary, type::16, 1::16>>
  end

  defp encode_name(name) do
    name
    |> String.split(".", trim: true)
    |> Enum.map_join(fn label -> <<byte_size(label)>> <> label end)
    |> Kernel.<>(<<0>>)
  end

  defp header(
         <<_id::16, flags::16, _qd::16, ancount::16, nscount::16, arcount::16, _rest::binary>>
       ) do
    %{ancount: ancount, nscount: nscount, arcount: arcount, rcode: Bitwise.band(flags, 0x000F)}
  end
end
