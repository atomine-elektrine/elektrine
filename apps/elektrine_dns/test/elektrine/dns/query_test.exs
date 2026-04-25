defmodule Elektrine.DNS.QueryTest do
  use ExUnit.Case, async: true

  alias Elektrine.DNS.Query
  alias Elektrine.DNS.Record
  alias Elektrine.DNS.Zone

  defmodule AliasResolverStub do
    def lookup(~c"edge.elektrine.com", :in, :a, timeout: 5_000), do: [{198, 51, 100, 99}]

    def lookup(~c"edge.elektrine.com", :in, :aaaa, timeout: 5_000),
      do: [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x99}]

    def lookup(_, _, _, timeout: 5_000), do: []
  end

  setup do
    previous_dns_config = Application.get_env(:elektrine, :dns, [])

    Application.put_env(
      :elektrine,
      :dns,
      Keyword.put(previous_dns_config, :alias_resolver, AliasResolverStub)
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :dns, previous_dns_config)
    end)

    zone = %Zone{
      domain: "example.com",
      records: [
        %Record{name: "@", type: "A", content: "203.0.113.10", ttl: 300},
        %Record{name: "root-alias.example.com", type: "A", content: "203.0.113.50", ttl: 300},
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
          key_tag: 12_345,
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
        },
        %Record{
          name: "ssh",
          type: "SSHFP",
          content: "1234ABCD",
          ttl: 300,
          algorithm: 4,
          digest_type: 2
        },
        %Record{
          name: "@",
          type: "HTTPS",
          content: ". alpn=h2,h3 port=443 ipv4hint=192.0.2.10",
          ttl: 300,
          priority: 1
        },
        %Record{
          name: "svc",
          type: "SVCB",
          content: "svc-target.example.com alpn=h2",
          ttl: 300,
          priority: 2
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

  test "answers SOA queries at the zone apex" do
    response = Query.answer(build_query("example.com", 6))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert first_answer_name(response) == "example.com"
  end

  test "answers authoritatively when recursion is not requested" do
    response = Query.answer(build_query("example.com", 6, rd: false))
    header = header(response)

    assert header.ancount == 1
    assert header.rcode == 0
    assert header.aa == 1
    assert header.rd == 0
    assert first_answer_name(response) == "example.com"
  end

  test "emits query telemetry metadata" do
    test_pid = self()
    handler_id = "dns-query-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:elektrine, :dns, :query],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:dns_query_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    _response = Query.answer(build_query("www.example.com", 1))

    assert_receive {:dns_query_telemetry, [:elektrine, :dns, :query], %{count: 1}, metadata}
    assert metadata.zone == "example.com"
    assert metadata.qname == "www.example.com"
    assert metadata.qtype == :a
    assert metadata.rcode == :noerror
    assert metadata.authoritative == true
  end

  test "truncates oversized UDP responses" do
    zone = %Zone{
      domain: "large.example.com",
      records: [
        %Record{name: "@", type: "TXT", content: String.duplicate("a", 900), ttl: 300}
      ]
    }

    :ets.insert(Elektrine.DNS.ZoneCache, {"large.example.com", zone})

    response = Query.answer(build_query("large.example.com", 16), transport: :udp)
    header = header(response)

    assert header.tc == 1
    assert header.ancount == 0
    assert header.rcode == 0
  end

  test "answers apex records stored as absolute names" do
    zone = %Zone{
      domain: "absolute.example.com",
      records: [
        %Record{name: "absolute.example.com", type: "A", content: "198.51.100.10", ttl: 300},
        %Record{name: "absolute.example.com", type: "TXT", content: "v=spf1 -all", ttl: 300},
        %Record{name: "ns1.absolute.example.com", type: "A", content: "198.51.100.11", ttl: 300},
        %Record{name: "ns2.absolute.example.com", type: "A", content: "198.51.100.12", ttl: 300}
      ]
    }

    :ets.insert(Elektrine.DNS.ZoneCache, {"absolute.example.com", zone})

    a_response = Query.answer(build_query("absolute.example.com", 1))
    txt_response = Query.answer(build_query("absolute.example.com", 16))
    ns1_response = Query.answer(build_query("ns1.absolute.example.com", 1))
    ns2_response = Query.answer(build_query("ns2.absolute.example.com", 1))

    assert a_response =~ <<198, 51, 100, 10>>
    assert txt_response =~ "v=spf1 -all"
    assert ns1_response =~ <<198, 51, 100, 11>>
    assert ns2_response =~ <<198, 51, 100, 12>>
  end

  test "answers apex MX records with the zone owner name" do
    zone = %Zone{
      domain: "mx.example.com",
      records: [
        %Record{name: "@", type: "MX", content: "mail.example.com", ttl: 300, priority: 10}
      ]
    }

    :ets.insert(Elektrine.DNS.ZoneCache, {"mx.example.com", zone})

    response = Query.answer(build_query("mx.example.com", 15))

    assert header(response).ancount == 1
    assert first_answer_name(response) == "mx.example.com"
  end

  test "returns cname answers for alias queries with requested A type" do
    response = Query.answer(build_query("alias.example.com", 1))

    assert header(response).ancount == 1
    assert header(response).arcount == 1
    assert header(response).rcode == 0
    assert response =~ "www"
    assert response =~ <<203, 0, 113, 20>>
  end

  test "flattens apex ALIAS records into A answers" do
    zone = %Zone{
      domain: "alias-a.example.com",
      records: [
        %Record{name: "@", type: "ALIAS", content: "edge.elektrine.com", ttl: 180}
      ]
    }

    :ets.insert(Elektrine.DNS.ZoneCache, {"alias-a.example.com", zone})

    response = Query.answer(build_query("alias-a.example.com", 1))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert first_answer_name(response) == "alias-a.example.com"
    assert response =~ <<198, 51, 100, 99>>
  end

  test "flattens apex ALIAS records into AAAA answers" do
    zone = %Zone{
      domain: "alias-aaaa.example.com",
      records: [
        %Record{name: "@", type: "ALIAS", content: "edge.elektrine.com", ttl: 180}
      ]
    }

    :ets.insert(Elektrine.DNS.ZoneCache, {"alias-aaaa.example.com", zone})

    response = Query.answer(build_query("alias-aaaa.example.com", 28))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert first_answer_name(response) == "alias-aaaa.example.com"
    assert response =~ <<0x20, 0x01, 0x0D, 0xB8>>
  end

  test "flattens local apex ALIAS targets without external lookup" do
    zone = %Zone{
      domain: "alias-local.example.com",
      records: [
        %Record{name: "@", type: "ALIAS", content: "edge.alias-local.example.com", ttl: 180},
        %Record{
          name: "edge.alias-local.example.com",
          type: "A",
          content: "203.0.113.50",
          ttl: 300
        }
      ]
    }

    :ets.insert(Elektrine.DNS.ZoneCache, {"alias-local.example.com", zone})

    response = Query.answer(build_query("alias-local.example.com", 1))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert response =~ <<203, 0, 113, 50>>
  end

  test "returns servfail instead of crashing on invalid A record content" do
    zone = %Zone{
      domain: "invalid-a.example.com",
      records: [
        %Record{name: "@", type: "A", content: "not-an-ip", ttl: 300}
      ]
    }

    :ets.insert(Elektrine.DNS.ZoneCache, {"invalid-a.example.com", zone})

    response = Query.answer(build_query("invalid-a.example.com", 1))

    assert header(response).ancount == 0
    assert header(response).rcode == 2
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

  test "answers SSHFP queries" do
    response = Query.answer(build_query("ssh.example.com", 44))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert response =~ <<4, 2, 0x12, 0x34, 0xAB, 0xCD>>
  end

  test "answers HTTPS queries" do
    response = Query.answer(build_query("example.com", 65))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert response =~ <<0, 1, 0, 0>>
    assert response =~ <<0, 1, 0, 6, 2, "h2", 2, "h3">>
    assert response =~ <<0, 3, 0, 2, 1, 0xBB>>
    assert response =~ <<0, 4, 0, 4, 192, 0, 2, 10>>
  end

  test "answers SVCB queries" do
    response = Query.answer(build_query("svc.example.com", 64))

    assert header(response).ancount == 1
    assert header(response).rcode == 0
    assert response =~ <<0, 2, 10, "svc-target", 7, "example", 3, "com", 0>>
    assert response =~ <<0, 1, 0, 3, 2, "h2">>
  end

  test "refuses ANY queries" do
    response = Query.answer(build_query("example.com", 255))

    assert header(response).ancount == 0
    assert header(response).rcode == 5
  end

  defp build_query(name, type, opts \\ []) do
    flags = if Keyword.get(opts, :rd, true), do: 0x0100, else: 0

    <<0x12, 0x34, flags::16, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
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
    %{
      aa: div(Bitwise.band(flags, 0x0400), 0x0400),
      tc: div(Bitwise.band(flags, 0x0200), 0x0200),
      rd: div(Bitwise.band(flags, 0x0100), 0x0100),
      ancount: ancount,
      nscount: nscount,
      arcount: arcount,
      rcode: Bitwise.band(flags, 0x000F)
    }
  end

  defp first_answer_name(
         <<_id::16, _flags::16, qd::16, ancount::16, _nscount::16, _arcount::16, rest::binary>> =
           packet
       )
       when qd == 1 and ancount > 0 do
    after_question = skip_question(rest)
    {:ok, answer_name, _after_answer_name} = decode_name(after_question, packet)
    answer_name
  end

  defp skip_question(rest) do
    {_qname, rest} = consume_name(rest)
    <<_qtype::16, _qclass::16, remaining::binary>> = rest
    remaining
  end

  defp consume_name(<<0, rest::binary>>), do: {"", rest}

  defp consume_name(<<len, _label::binary-size(len), rest::binary>>) do
    consume_name(rest)
  end

  defp decode_name(data, packet), do: decode_name(data, packet, [], 0)

  defp decode_name(_, _, _, 20), do: {:error, :compression_loop}

  defp decode_name(<<0, rest::binary>>, _packet, labels, _depth),
    do: {:ok, Enum.reverse(labels) |> Enum.join("."), rest}

  defp decode_name(<<len, _::binary>> = data, packet, labels, depth)
       when Bitwise.band(len, 0xC0) == 0xC0 do
    <<ptr::16, rest::binary>> = data
    offset = Bitwise.band(ptr, 0x3FFF)

    with true <- offset < byte_size(packet),
         {:ok, pointed, _} <-
           decode_name(
             binary_part(packet, offset, byte_size(packet) - offset),
             packet,
             [],
             depth + 1
           ) do
      {:ok, (Enum.reverse(labels) ++ String.split(pointed, ".", trim: true)) |> Enum.join("."),
       rest}
    else
      _ -> {:error, :bad_pointer}
    end
  end

  defp decode_name(<<len, label::binary-size(len), rest::binary>>, packet, labels, depth),
    do: decode_name(rest, packet, [label | labels], depth)
end
