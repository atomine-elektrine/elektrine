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
        %Record{name: "mx", type: "A", content: "203.0.113.40", ttl: 300}
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
