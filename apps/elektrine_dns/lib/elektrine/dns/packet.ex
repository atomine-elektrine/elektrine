defmodule Elektrine.DNS.Packet do
  @moduledoc false

  import Bitwise

  alias Elektrine.DNS
  alias Elektrine.DNS.ServiceBinding

  @type_map %{
    a: 1,
    ns: 2,
    cname: 5,
    soa: 6,
    hinfo: 13,
    mx: 15,
    txt: 16,
    aaaa: 28,
    srv: 33,
    sshfp: 44,
    ds: 43,
    dnskey: 48,
    tlsa: 52,
    svcb: 64,
    https: 65,
    caa: 257,
    any: 255
  }
  @rcode_map %{noerror: 0, formerr: 1, servfail: 2, nxdomain: 3, notimp: 4, refused: 5}
  @type_numbers @type_map |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  @type_names @type_map |> Map.new(fn {key, _value} -> {Atom.to_string(key), key} end)

  def decode_query(packet) when is_binary(packet) do
    with <<id::16, flags::16, qdcount::16, ancount::16, nscount::16, arcount::16, rest::binary>> <-
           packet,
         true <- qdcount == 1,
         true <- opcode(flags) == 0,
         true <- ancount == 0,
         true <- nscount == 0,
         {:ok, question, rest} <- decode_question(rest, packet),
         true <- question.qclass == 1,
         {:ok, options} <- decode_query_options(rest, packet, arcount) do
      {:ok,
       %{
         id: id,
         flags: flags,
         rd: flags >>> 8 &&& 1,
         qname: question.qname,
         qtype: question.qtype,
         qclass: question.qclass,
         udp_size: options.udp_size,
         dnssec_ok: options.dnssec_ok,
         edns: options.edns
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

  def encode_query(%{id: id, rd: rd, qname: qname, qtype: qtype} = query) do
    flags = if rd in [1, true], do: 1 <<< 8, else: 0
    question = encode_name(qname) <> <<encode_type(qtype)::16, 1::16>>

    case encode_opt_record(Map.get(query, :udp_size), Map.get(query, :dnssec_ok, false)) do
      nil ->
        <<id::16, flags::16, 1::16, 0::16, 0::16, 0::16, question::binary>>

      opt_record ->
        <<id::16, flags::16, 1::16, 0::16, 0::16, 1::16, question::binary, opt_record::binary>>
    end
  end

  def encode_response(query, answers, rcode, opts \\ []) do
    do_encode_response(query, answers, rcode, opts)
  rescue
    # A record that fails to encode must never leave the client without an
    # answer, so any encode error degrades to a bare SERVFAIL.
    _error -> do_encode_response(query, [], :servfail, transport_opts(opts))
  end

  defp do_encode_response(query, answers, rcode, opts) do
    flags = flags_for_reply(query.rd, rcode, opts)
    question = encode_name(query.qname) <> <<encode_type(query.qtype)::16, 1::16>>
    qname_norm = normalize_owner(query.qname)
    answer_bin = Enum.map_join(answers, &encode_record(&1, qname_norm))
    authority = Keyword.get(opts, :authority, [])
    additional = Keyword.get(opts, :additional, [])
    authority_bin = Enum.map_join(authority, &encode_record(&1, qname_norm))
    additional_bin = Enum.map_join(additional, &encode_record(&1, qname_norm))
    opt_bin = response_opt_record(query)
    arcount = length(additional) + if opt_bin == <<>>, do: 0, else: 1

    response =
      <<query.id::16, flags::16, 1::16, length(answers)::16, length(authority)::16, arcount::16,
        question::binary, answer_bin::binary, authority_bin::binary, additional_bin::binary,
        opt_bin::binary>>

    maybe_truncate_response(query, response, rcode, opts)
  end

  # RFC 6891/3225: a response to an EDNS query must carry an OPT record, with
  # the DO bit copied from the request.
  defp response_opt_record(query) do
    if Map.get(query, :edns, false) do
      encode_opt_record(DNS.max_udp_payload(), Map.get(query, :dnssec_ok, false))
    else
      <<>>
    end
  end

  defp transport_opts(opts) do
    case Keyword.fetch(opts, :transport) do
      {:ok, transport} -> [transport: transport]
      :error -> []
    end
  end

  defp flags_for_reply(rd, rcode, opts \\ []) do
    aa = if Keyword.get(opts, :authoritative, false), do: 1 <<< 10, else: 0
    ra = if Keyword.get(opts, :recursion_available, false), do: 1 <<< 7, else: 0
    tc = if Keyword.get(opts, :truncated, false), do: 1 <<< 9, else: 0
    ad = if Keyword.get(opts, :authentic_data, false), do: 1 <<< 5, else: 0

    1 <<< 15 ||| aa ||| tc ||| rd <<< 8 ||| ra ||| ad ||| Map.fetch!(@rcode_map, rcode)
  end

  defp maybe_truncate_response(query, response, rcode, opts) do
    if Keyword.get(opts, :transport) == :udp and byte_size(response) > udp_payload_limit(query) do
      encode_truncated_response(query, rcode, opts)
    else
      response
    end
  end

  defp encode_truncated_response(query, rcode, opts) do
    flags = flags_for_reply(query.rd, rcode, Keyword.put(opts, :truncated, true))
    question = encode_name(query.qname) <> <<encode_type(query.qtype)::16, 1::16>>
    opt_bin = response_opt_record(query)
    arcount = if opt_bin == <<>>, do: 0, else: 1

    <<query.id::16, flags::16, 1::16, 0::16, 0::16, arcount::16, question::binary,
      opt_bin::binary>>
  end

  defp udp_payload_limit(query) do
    query
    |> Map.get(:udp_size, 512)
    |> max(512)
    |> min(max(DNS.max_udp_payload(), 512))
  end

  defp opcode(flags), do: flags >>> 11 &&& 0xF

  def decode_question(packet) when is_binary(packet) do
    with <<_id::16, _flags::16, qdcount::16, _ancount::16, _nscount::16, _arcount::16,
           rest::binary>> <- packet,
         true <- qdcount == 1,
         {:ok, question, _rest} <- decode_question(rest, packet) do
      {:ok, question}
    else
      _ -> {:error, :format_error}
    end
  end

  defp decode_question(rest, packet) do
    with {:ok, qname, rest} <- decode_name(rest, packet),
         <<qtype::16, qclass::16, rest::binary>> <- rest do
      {:ok, %{qname: qname, qtype: decode_type(qtype), qclass: qclass}, rest}
    else
      _ -> {:error, :format_error}
    end
  end

  defp decode_query_options(_rest, _packet, 0),
    do: {:ok, %{udp_size: 512, dnssec_ok: false, edns: false}}

  defp decode_query_options(rest, packet, arcount) do
    decode_additional_records(rest, packet, arcount, %{
      udp_size: 512,
      dnssec_ok: false,
      edns: false
    })
  end

  defp decode_additional_records(rest, _packet, 0, options) when is_binary(rest),
    do: {:ok, options}

  defp decode_additional_records(data, packet, remaining, options) when remaining > 0 do
    with {:ok, name, rest} <- decode_name(data, packet),
         <<type::16, class::16, ttl::32, rdlength::16, _rdata::binary-size(rdlength),
           rest::binary>> <- rest do
      options =
        if type == 41 and name == "" do
          %{
            options
            | udp_size: clamp_udp_size(class),
              dnssec_ok: (ttl &&& 0x8000) != 0,
              edns: true
          }
        else
          options
        end

      decode_additional_records(rest, packet, remaining - 1, options)
    else
      _ -> {:error, :format_error}
    end
  end

  defp clamp_udp_size(size) when size < 512, do: 512
  defp clamp_udp_size(size), do: min(size, max(DNS.max_udp_payload(), 512))

  defp encode_opt_record(nil, false), do: nil

  defp encode_opt_record(udp_size, dnssec_ok) do
    udp_size = udp_size || DNS.max_udp_payload()
    flags = if dnssec_ok, do: 0x8000, else: 0
    <<0, 41::16, clamp_udp_size(udp_size)::16, 0::8, 0::8, flags::16, 0::16>>
  end

  defp decode_name(data, packet), do: decode_name(data, packet, [], 0)

  defp decode_name(_, _, _, 20), do: {:error, :compression_loop}

  defp decode_name(<<0, rest::binary>>, _packet, labels, _depth) do
    name = Enum.reverse(labels) |> Enum.join(".")

    if byte_size(name) <= 253 do
      {:ok, name, rest}
    else
      {:error, :name_too_long}
    end
  end

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

  defp decode_name(<<len, _::binary>>, _packet, _labels, _depth) when (len &&& 0xC0) != 0,
    do: {:error, :bad_label}

  defp decode_name(<<len, label::binary-size(len), rest::binary>>, packet, labels, depth)
       when len <= 63,
       do: decode_name(rest, packet, [label | labels], depth)

  defp decode_name(_, _, _, _), do: {:error, :bad_name}

  defp encode_record(record, qname_norm) do
    name = encode_owner(record_name(record), qname_norm)
    type = encode_type(record.type)
    ttl = Map.get(record, :ttl, 300)
    rdata = encode_rdata(Map.put(record, :type, normalize_type(record.type)))

    <<name::binary, type::16, 1::16, ttl::32, byte_size(rdata)::16, rdata::binary>>
  end

  # Owner names matching the question name are emitted as a compression
  # pointer to the question section (fixed offset 12).
  defp encode_owner(name, qname_norm) do
    if qname_norm != nil and normalize_owner(name) == qname_norm do
      <<0xC00C::16>>
    else
      encode_name(name)
    end
  end

  defp normalize_owner(name) do
    name |> to_string() |> String.trim_trailing(".") |> String.downcase()
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

  defp encode_rdata(%{type: :hinfo, cpu: cpu, os: os}),
    do: <<byte_size(cpu)::8, cpu::binary, byte_size(os)::8, os::binary>>

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

  defp encode_rdata(%{
         type: :dnskey,
         content: content,
         flags: flags,
         protocol: protocol,
         algorithm: algorithm
       }) do
    <<flags || 0::16, protocol || 3::8, algorithm || 0::8, decode_base64_data(content)::binary>>
  end

  defp encode_rdata(%{
         type: :ds,
         content: content,
         key_tag: key_tag,
         algorithm: algorithm,
         digest_type: digest_type
       }) do
    <<key_tag || 0::16, algorithm || 0::8, digest_type || 0::8, decode_hex_data(content)::binary>>
  end

  defp encode_rdata(%{
         type: :tlsa,
         content: content,
         usage: usage,
         selector: selector,
         matching_type: matching_type
       }) do
    <<usage || 0::8, selector || 0::8, matching_type || 0::8, decode_hex_data(content)::binary>>
  end

  defp encode_rdata(%{
         type: :sshfp,
         content: content,
         algorithm: algorithm,
         digest_type: digest_type
       }) do
    <<algorithm || 0::8, digest_type || 0::8, decode_hex_data(content)::binary>>
  end

  defp encode_rdata(%{type: type, priority: priority, content: content})
       when type in [:svcb, :https] do
    case ServiceBinding.encode_rdata(priority || 0, content, &encode_name/1) do
      {:ok, rdata} -> rdata
      {:error, reason} -> raise ArgumentError, "invalid service binding record: #{reason}"
    end
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

  defp decode_base64_data(content) when is_binary(content) do
    case Base.decode64(content) do
      {:ok, decoded} ->
        decoded

      :error ->
        case Base.decode64(content, padding: false) do
          {:ok, decoded} -> decoded
          :error -> raise ArgumentError, "invalid DNS base64 record content"
        end
    end
  end

  defp decode_hex_data(content) when is_binary(content) do
    case Base.decode16(content, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> raise ArgumentError, "invalid DNS hexadecimal record content"
    end
  end

  defp encode_name(name) do
    normalized = name |> to_string() |> String.trim_trailing(".")
    labels = String.split(normalized, ".", trim: true)

    if byte_size(normalized) > 253 or Enum.any?(labels, &(byte_size(&1) > 63)) do
      raise ArgumentError, "DNS name is too long"
    end

    labels
    |> Enum.map_join(fn label -> <<byte_size(label)>> <> label end)
    |> Kernel.<>(<<0>>)
  end

  defp record_name(%{host: host}), do: host
  defp record_name(%{name: name}), do: name

  defp decode_type(type),
    do: Enum.find_value(@type_map, type, fn {key, value} -> if value == type, do: key end)

  defp encode_type(type) when is_binary(type),
    do: Map.get(@type_numbers, String.downcase(type), 255)

  defp encode_type(type) when is_integer(type), do: type
  defp encode_type(type) when is_atom(type), do: Map.get(@type_map, type, 255)

  defp normalize_type(type) when is_binary(type),
    do: Map.get(@type_names, String.downcase(type), 255)

  defp normalize_type(type), do: type
end
