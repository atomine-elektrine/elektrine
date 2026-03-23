defmodule Elektrine.DNS.Packet do
  @moduledoc false

  import Bitwise

  @type_map %{
    a: 1,
    ns: 2,
    cname: 5,
    soa: 6,
    mx: 15,
    txt: 16,
    aaaa: 28,
    srv: 33,
    caa: 257,
    any: 255
  }
  @rcode_map %{noerror: 0, formerr: 1, servfail: 2, nxdomain: 3, notimp: 4, refused: 5}

  def decode_query(packet) when is_binary(packet) do
    with <<id::16, flags::16, qdcount::16, _ancount::16, _nscount::16, _arcount::16,
           rest::binary>> <- packet,
         true <- qdcount >= 1,
         {:ok, qname, rest} <- decode_name(rest, packet),
         <<qtype::16, qclass::16, _::binary>> <- rest,
         true <- qclass == 1 do
      {:ok,
       %{
         id: id,
         flags: flags,
         rd: flags >>> 8 &&& 1,
         qname: qname,
         qtype: decode_type(qtype),
         qclass: qclass
       }}
    else
      _ -> {:error, :format_error}
    end
  end

  def encode_error(packet, rcode) when is_binary(packet) do
    case decode_query(packet) do
      {:ok, query} -> encode_response(query, [], rcode)
      _ -> <<0::16, flags_for_reply(0, rcode)::16, 0::16, 0::16, 0::16, 0::16>>
    end
  end

  def encode_response(query, answers, rcode, opts \\ []) do
    flags = flags_for_reply(query.rd, rcode)
    question = encode_name(query.qname) <> <<encode_type(query.qtype)::16, 1::16>>
    answer_bin = Enum.map_join(answers, &encode_record(&1))
    authority = Keyword.get(opts, :authority, [])
    additional = Keyword.get(opts, :additional, [])
    authority_bin = Enum.map_join(authority, &encode_record(&1))
    additional_bin = Enum.map_join(additional, &encode_record(&1))

    <<query.id::16, flags::16, 1::16, length(answers)::16, length(authority)::16,
      length(additional)::16, question::binary, answer_bin::binary, authority_bin::binary,
      additional_bin::binary>>
  end

  defp flags_for_reply(rd, rcode) do
    1 <<< 15 ||| 1 <<< 10 ||| rd <<< 8 ||| Map.fetch!(@rcode_map, rcode)
  end

  defp decode_name(data, packet), do: decode_name(data, packet, [], 0)

  defp decode_name(_, _, _, 20), do: {:error, :compression_loop}

  defp decode_name(<<0, rest::binary>>, _packet, labels, _depth),
    do: {:ok, Enum.reverse(labels) |> Enum.join("."), rest}

  defp decode_name(<<len, _::binary>> = data, packet, labels, depth)
       when (len &&& 0xC0) == 0xC0 do
    <<ptr::16, rest::binary>> = data
    offset = ptr &&& 0x3FFF

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

  defp decode_name(_, _, _, _), do: {:error, :bad_name}

  defp encode_record(record) do
    name = encode_name(record_name(record))
    type = encode_type(record.type)
    ttl = Map.get(record, :ttl, 300)
    rdata = encode_rdata(%{record | type: normalize_type(record.type)})

    <<name::binary, type::16, 1::16, ttl::32, byte_size(rdata)::16, rdata::binary>>
  end

  defp encode_rdata(%{type: :a, content: content}) do
    {:ok, {a, b, c, d}} = :inet.parse_address(String.to_charlist(content))
    <<a, b, c, d>>
  end

  defp encode_rdata(%{type: :aaaa, content: content}) do
    {:ok, tuple} = :inet.parse_address(String.to_charlist(content))
    tuple |> Tuple.to_list() |> Enum.map_join(&<<&1::16>>)
  end

  defp encode_rdata(%{type: :ns, value: value}), do: encode_name(value)
  defp encode_rdata(%{type: :cname, content: content}), do: encode_name(content)

  defp encode_rdata(%{type: :mx, content: content, priority: priority}),
    do: <<priority || 10::16, encode_name(content)::binary>>

  defp encode_rdata(%{type: :txt, content: content}), do: encode_txt(content)
  defp encode_rdata(%{type: :txt, value: value}), do: encode_txt(value)

  defp encode_rdata(%{
         type: :srv,
         content: content,
         priority: priority,
         weight: weight,
         port: port
       }) do
    <<priority || 0::16, weight || 0::16, port || 0::16, encode_name(content)::binary>>
  end

  defp encode_rdata(%{type: :caa, flags: flags, tag: tag, content: content}) do
    tag = tag || "issue"
    <<flags || 0::8, byte_size(tag)::8, tag::binary, content::binary>>
  end

  defp encode_rdata(%{content: content}) when is_binary(content), do: content
  defp encode_rdata(%{value: value}) when is_binary(value), do: value

  defp encode_rdata(%{
         type: :soa,
         mname: mname,
         rname: rname,
         serial: serial,
         refresh: refresh,
         retry: retry,
         expire: expire,
         minimum: minimum
       }) do
    <<encode_name(mname)::binary, encode_name(rname)::binary, serial::32, refresh::32, retry::32,
      expire::32, minimum::32>>
  end

  defp encode_txt(content) do
    content
    |> to_string()
    |> :binary.bin_to_list()
    |> Enum.chunk_every(255)
    |> Enum.map_join(fn chunk -> <<length(chunk)>> <> :erlang.list_to_binary(chunk) end)
  end

  defp encode_name(name) do
    normalized = name |> to_string() |> String.trim_trailing(".")

    normalized
    |> String.split(".", trim: true)
    |> Enum.map_join(fn label -> <<byte_size(label)>> <> label end)
    |> Kernel.<>(<<0>>)
  end

  defp record_name(%{host: host}), do: host
  defp record_name(%{name: name}), do: name

  defp decode_type(type),
    do: Enum.find_value(@type_map, :any, fn {key, value} -> if value == type, do: key end)

  defp encode_type(type) when is_binary(type),
    do: type |> String.downcase() |> String.to_atom() |> encode_type()

  defp encode_type(type) when is_atom(type), do: Map.get(@type_map, type, 255)

  defp normalize_type(type) when is_binary(type),
    do: type |> String.downcase() |> String.to_atom()

  defp normalize_type(type), do: type
end
