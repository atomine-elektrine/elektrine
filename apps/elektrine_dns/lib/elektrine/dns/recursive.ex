defmodule Elektrine.DNS.Recursive do
  @moduledoc false

  import Bitwise

  alias Elektrine.DNS
  alias Elektrine.DNS.Packet
  alias Elektrine.DNS.RecursiveCache

  @max_depth 12
  @supported_types [:a, :aaaa, :ns, :cname, :mx, :txt, :srv, :ds, :dnskey, :tlsa]

  def resolve(packet, opts \\ []) when is_binary(packet) do
    case Packet.decode_query(packet) do
      {:ok, query} ->
        do_resolve(query, opts)

      {:error, :format_error} ->
        Packet.encode_error(packet, :formerr)

      _ ->
        Packet.encode_error(packet, :servfail)
    end
  end

  def allow_recursive?(client_ip), do: authorize_client(client_ip) == :ok

  defp do_resolve(query, opts) do
    response_opts = [recursion_available: true, transport: Keyword.get(opts, :transport)]

    cond do
      not DNS.recursive_enabled?() ->
        Packet.encode_response(query, [], :refused, response_opts)

      query.qtype == :any ->
        Packet.encode_response(query, [], :refused, response_opts)

      not forwarding_mode?() and query.qtype not in @supported_types ->
        Packet.encode_response(query, [], :notimp, response_opts)

      authorize_client(Keyword.get(opts, :client_ip)) != :ok ->
        Packet.encode_response(query, [], :refused, response_opts)

      true ->
        case cached_or_iterative_resolve(query, MapSet.new()) do
          {:ok, result} ->
            Packet.encode_response(query, result.answers, result.rcode,
              authority: result.authority,
              additional: result.additional,
              authentic_data: Map.get(result, :authentic_data, false),
              recursion_available: true,
              transport: Keyword.get(opts, :transport)
            )

          {:error, :refused} ->
            Packet.encode_response(query, [], :refused, response_opts)

          {:error, :unsupported_type} ->
            Packet.encode_response(query, [], :notimp, response_opts)

          {:error, _reason} ->
            Packet.encode_response(query, [], :servfail, response_opts)
        end
    end
  end

  defp cached_or_iterative_resolve(query, seen_cnames) do
    cache_key = {normalize_name(query.qname), query.qtype}

    case RecursiveCache.get(cache_key) do
      {:ok, result} -> {:ok, result}
      :error -> uncached_resolve(query, seen_cnames)
    end
  end

  defp uncached_resolve(query, seen_cnames) do
    case DNS.recursive_upstreams() do
      [] -> iterative_resolve(query, DNS.recursive_root_hints(), 0, seen_cnames)
      upstreams -> forward_resolve(query, upstreams)
    end
  end

  defp iterative_resolve(_query, _servers, depth, _seen_cnames) when depth > @max_depth,
    do: {:error, :max_depth}

  defp iterative_resolve(query, servers, depth, seen_cnames) do
    with {:ok, response} <- query_nameservers(query, servers),
         {:ok, decoded} <- decode_response(response) do
      handle_response(query, decoded, depth, seen_cnames)
    end
  end

  defp forward_resolve(query, upstreams) do
    with {:ok, response} <- query_upstreams(query, upstreams),
         {:ok, decoded} <- decode_response(response) do
      result = %{
        answers: convert_records(answer_records(decoded)),
        authority: convert_records(authority_records(decoded)),
        additional: convert_records(additional_records(decoded)),
        rcode: message_rcode(decoded),
        authentic_data: authentic_data?(response)
      }

      if cacheable_rcode?(result.rcode) do
        cache_result(query, result)
      else
        {:ok, result}
      end
    end
  end

  defp handle_response(query, decoded, depth, seen_cnames) do
    rcode = message_rcode(decoded)
    answers = convert_records(answer_records(decoded))
    authority = convert_records(authority_records(decoded))
    additional = convert_records(additional_records(decoded))

    cond do
      rcode == :nxdomain ->
        result = %{answers: [], authority: authority, additional: additional, rcode: :nxdomain}
        cache_result(query, result)

      matching_answers?(answers, query.qtype) ->
        result = %{
          answers: answers,
          authority: authority,
          additional: additional,
          rcode: :noerror
        }

        cache_result(query, result)

      cname = first_cname_answer(answers) ->
        follow_cname(query, cname, answers, depth, seen_cnames)

      referral_ns = referral_nameservers(decoded) ->
        follow_referral(query, referral_ns, decoded, depth, seen_cnames)

      true ->
        {:error, :servfail}
    end
  end

  defp follow_cname(query, cname, existing_answers, _depth, seen_cnames) do
    target = normalize_name(cname.content)

    if MapSet.member?(seen_cnames, target) do
      {:error, :cname_loop}
    else
      alias_query = %{query | qname: target}

      case cached_or_iterative_resolve(alias_query, MapSet.put(seen_cnames, target)) do
        {:ok, result} ->
          merged = %{result | answers: existing_answers ++ result.answers}
          cache_result(query, merged)

        error ->
          error
      end
    end
  end

  defp follow_referral(query, ns_names, decoded, depth, seen_cnames) do
    glue_ips = glue_ips_for_ns(ns_names, decoded)

    next_servers =
      if glue_ips == [] do
        ns_names
        |> Enum.flat_map(&resolve_nameserver_ips(&1, depth, seen_cnames))
        |> Enum.uniq()
      else
        Enum.map(glue_ips, &{&1, 53})
      end

    if next_servers == [] do
      {:error, :no_referral_addresses}
    else
      iterative_resolve(query, rotate_servers(next_servers, query.id), depth + 1, seen_cnames)
    end
  end

  defp resolve_nameserver_ips(name, _depth, seen_cnames) do
    qname = normalize_name(name)

    @supported_types
    |> Enum.filter(&(&1 in [:a, :aaaa]))
    |> Enum.flat_map(fn qtype ->
      case cached_or_iterative_resolve(%{id: 0, rd: 0, qname: qname, qtype: qtype}, seen_cnames) do
        {:ok, result} ->
          result.answers
          |> Enum.filter(&(&1.type in [:a, :aaaa]))
          |> Enum.map(&{record_ip(&1), 53})

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp query_nameservers(query, servers) do
    {upstream_query, packet} = build_upstream_query(query, rd: 0, dnssec_ok: false)

    servers
    |> rotate_servers(query.id)
    |> Enum.reduce_while({:error, :timeout}, fn {ip, port}, _acc ->
      case exchange_udp(ip, port, packet, DNS.recursive_timeout()) do
        {:ok, response} ->
          final = maybe_retry_over_tcp(ip, port, packet, response)

          case valid_upstream_response?(upstream_query, final) do
            true -> {:halt, {:ok, final}}
            false -> {:cont, {:error, :invalid_response}}
          end

        {:error, _reason} = error ->
          {:cont, error}
      end
    end)
  end

  defp query_upstreams(query, upstreams) do
    {upstream_query, packet} = build_upstream_query(query, rd: 1, dnssec_ok: true)

    upstreams
    |> rotate_servers(query.id)
    |> Enum.reduce_while({:error, :timeout}, fn {ip, port}, _acc ->
      case exchange_udp(ip, port, packet, DNS.recursive_timeout()) do
        {:ok, response} ->
          final = maybe_retry_over_tcp(ip, port, packet, response)

          case valid_upstream_response?(upstream_query, final) do
            true -> {:halt, {:ok, final}}
            false -> {:cont, {:error, :invalid_response}}
          end

        {:error, _reason} = error ->
          {:cont, error}
      end
    end)
  end

  defp build_upstream_query(query, opts) do
    upstream_query =
      query
      |> Map.merge(%{
        udp_size: DNS.max_udp_payload(),
        dnssec_ok: Keyword.get(opts, :dnssec_ok, false)
      })
      |> Map.put(:id, random_id())
      |> Map.put(:rd, Keyword.get(opts, :rd, 0))

    {upstream_query, Packet.encode_query(upstream_query)}
  end

  defp decode_response(response) do
    case :inet_dns.decode(response) do
      {:ok, decoded} -> {:ok, decoded}
      other -> other
    end
  end

  defp matching_answers?(answers, :any), do: answers != []
  defp matching_answers?(answers, qtype), do: Enum.any?(answers, &(&1.type == qtype))

  defp first_cname_answer(answers), do: Enum.find(answers, &(&1.type == :cname))

  defp referral_nameservers(decoded) do
    decoded
    |> authority_records()
    |> Enum.filter(&(normalize_rr_type(rr_type(&1)) == :ns))
    |> Enum.map(&rr_data/1)
    |> Enum.map(&normalize_name/1)
    |> Enum.uniq()
  end

  defp glue_ips_for_ns(ns_names, decoded) do
    delegated_names = referral_domains(decoded)

    decoded
    |> additional_records()
    |> Enum.filter(fn record ->
      normalize_rr_type(rr_type(record)) in [:a, :aaaa] and
        normalize_name(rr_domain(record)) in ns_names and
        within_bailiwick?(normalize_name(rr_domain(record)), delegated_names)
    end)
    |> Enum.map(&rr_ip/1)
  end

  defp referral_domains(decoded) do
    decoded
    |> authority_records()
    |> Enum.filter(&(normalize_rr_type(rr_type(&1)) == :ns))
    |> Enum.map(&rr_domain/1)
    |> Enum.uniq()
  end

  defp convert_records(records) do
    records
    |> Enum.map(&convert_record/1)
    |> Enum.reject(&is_nil/1)
  end

  defp convert_record(rr) do
    case normalize_rr_type(rr_type(rr)) do
      :a ->
        %{name: rr_domain(rr), type: :a, content: rr_ip(rr), ttl: rr_ttl(rr)}

      :aaaa ->
        %{name: rr_domain(rr), type: :aaaa, content: rr_ip(rr), ttl: rr_ttl(rr)}

      :ns ->
        %{name: rr_domain(rr), type: :ns, value: rr_data(rr) |> to_string(), ttl: rr_ttl(rr)}

      :cname ->
        %{name: rr_domain(rr), type: :cname, content: rr_data(rr) |> to_string(), ttl: rr_ttl(rr)}

      :txt ->
        %{name: rr_domain(rr), type: :txt, content: txt_content(rr_data(rr)), ttl: rr_ttl(rr)}

      :mx ->
        {priority, exchange} = rr_data(rr)

        %{
          name: rr_domain(rr),
          type: :mx,
          priority: priority,
          content: to_string(exchange),
          ttl: rr_ttl(rr)
        }

      :srv ->
        {priority, weight, port, target} = rr_data(rr)

        %{
          name: rr_domain(rr),
          type: :srv,
          priority: priority,
          weight: weight,
          port: port,
          content: to_string(target),
          ttl: rr_ttl(rr)
        }

      :ds ->
        {key_tag, algorithm, digest_type, digest} = decode_ds_data(rr_data(rr))

        %{
          name: rr_domain(rr),
          type: :ds,
          key_tag: key_tag,
          algorithm: algorithm,
          digest_type: digest_type,
          content: Base.encode16(digest, case: :upper),
          ttl: rr_ttl(rr)
        }

      :dnskey ->
        {flags, protocol, algorithm, public_key} = decode_dnskey_data(rr_data(rr))

        %{
          name: rr_domain(rr),
          type: :dnskey,
          flags: flags,
          protocol: protocol,
          algorithm: algorithm,
          content: Base.encode64(public_key),
          ttl: rr_ttl(rr)
        }

      :tlsa ->
        {usage, selector, matching_type, association_data} = decode_tlsa_data(rr_data(rr))

        %{
          name: rr_domain(rr),
          type: :tlsa,
          usage: usage,
          selector: selector,
          matching_type: matching_type,
          content: Base.encode16(association_data, case: :upper),
          ttl: rr_ttl(rr)
        }

      :soa ->
        {mname, rname, serial, refresh, retry, expire, minimum} = rr_data(rr)

        %{
          name: rr_domain(rr),
          type: :soa,
          mname: to_string(mname),
          rname: to_string(rname),
          serial: serial,
          refresh: refresh,
          retry: retry,
          expire: expire,
          minimum: minimum,
          ttl: rr_ttl(rr)
        }

      _ ->
        nil
    end
  end

  defp cache_result(query, result) do
    ttl = cache_ttl(result)
    RecursiveCache.put({normalize_name(query.qname), query.qtype}, result, ttl)
    {:ok, result}
  end

  defp cache_ttl(result) do
    if result.answers == [] do
      negative_cache_ttl(result.authority)
    else
      result
      |> Map.take([:answers, :authority, :additional])
      |> Map.values()
      |> List.flatten()
      |> Enum.map(&Map.get(&1, :ttl, 60))
      |> Enum.reject(&(&1 <= 0))
      |> Enum.min(fn -> 60 end)
    end
  end

  defp negative_cache_ttl(authority) do
    authority
    |> Enum.find(&(&1.type == :soa))
    |> case do
      %{minimum: minimum, ttl: ttl} when is_integer(minimum) and minimum > 0 -> min(minimum, ttl)
      %{ttl: ttl} when is_integer(ttl) and ttl > 0 -> ttl
      _ -> 60
    end
  end

  defp exchange_udp(ip, port, packet, timeout) do
    DNS.recursive_transport().exchange_udp(ip, port, packet, timeout)
  end

  defp exchange_tcp(ip, port, packet, timeout) do
    DNS.recursive_transport().exchange_tcp(ip, port, packet, timeout)
  end

  defp maybe_retry_over_tcp(ip, port, packet, udp_response) do
    if truncated?(udp_response) do
      case exchange_tcp(ip, port, packet, DNS.recursive_timeout()) do
        {:ok, tcp_response} -> tcp_response
        {:error, _reason} -> udp_response
      end
    else
      udp_response
    end
  end

  defp truncated?(<<_id::16, flags::16, _rest::binary>>), do: (flags &&& 0x0200) != 0
  defp truncated?(_), do: false

  defp rotate_servers(servers, query_id) when is_list(servers) and servers != [] do
    offset = rem(max(query_id, 0), length(servers))
    Enum.drop(servers, offset) ++ Enum.take(servers, offset)
  end

  defp rotate_servers(servers, _query_id), do: servers

  defp random_id do
    :rand.uniform(65_536) - 1
  end

  defp forwarding_mode?, do: DNS.recursive_upstreams() != []

  defp authorize_client(nil), do: :ok

  defp authorize_client(client_ip) do
    allowed = parsed_allow_cidrs()

    if Enum.any?(allowed, &cidr_match?(client_ip, &1)) do
      :ok
    else
      {:error, :refused}
    end
  end

  defp parse_cidr(cidr) do
    [address, prefix] = String.split(cidr, "/", parts: 2)
    {:ok, ip} = :inet.parse_address(String.to_charlist(address))
    {ip, String.to_integer(prefix)}
  end

  defp cidr_match?(ip, {network, prefix}) when tuple_size(ip) == tuple_size(network) do
    bits = if tuple_size(ip) == 4, do: 32, else: 128
    ip_int = ip_to_integer(ip)
    net_int = ip_to_integer(network)
    mask = ((1 <<< prefix) - 1) <<< (bits - prefix)
    (ip_int &&& mask) == (net_int &&& mask)
  end

  defp cidr_match?(_, _), do: false

  defp parsed_allow_cidrs do
    cidrs = DNS.recursive_allow_cidrs()
    key = {__MODULE__, :parsed_allow_cidrs}

    case :persistent_term.get(key, :missing) do
      {^cidrs, parsed} ->
        parsed

      _ ->
        parsed = Enum.map(cidrs, &parse_cidr/1)
        :persistent_term.put(key, {cidrs, parsed})
        parsed
    end
  end

  defp ip_to_integer(tuple) do
    step = if tuple_size(tuple) == 4, do: 8, else: 16

    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, acc -> (acc <<< step) + segment end)
  end

  defp message_rcode({:dns_rec, header, _qd, _an, _ns, _ar}) do
    case elem(header, 9) do
      0 -> :noerror
      1 -> :formerr
      2 -> :servfail
      3 -> :nxdomain
      4 -> :notimp
      5 -> :refused
      other -> other
    end
  end

  defp answer_records({:dns_rec, _header, _qd, answers, _ns, _ar}), do: answers
  defp authority_records({:dns_rec, _header, _qd, _an, authority, _ar}), do: authority
  defp additional_records({:dns_rec, _header, _qd, _an, _ns, additional}), do: additional

  defp rr_domain(rr), do: rr |> elem(1) |> to_string() |> normalize_name()
  defp rr_type(rr), do: elem(rr, 2)
  defp rr_ttl(rr), do: elem(rr, 5)
  defp rr_data(rr), do: elem(rr, 6)

  defp normalize_rr_type(1), do: :a
  defp normalize_rr_type(2), do: :ns
  defp normalize_rr_type(5), do: :cname
  defp normalize_rr_type(6), do: :soa
  defp normalize_rr_type(15), do: :mx
  defp normalize_rr_type(16), do: :txt
  defp normalize_rr_type(28), do: :aaaa
  defp normalize_rr_type(33), do: :srv
  defp normalize_rr_type(43), do: :ds
  defp normalize_rr_type(48), do: :dnskey
  defp normalize_rr_type(52), do: :tlsa
  defp normalize_rr_type(type), do: type

  defp decode_ds_data({key_tag, algorithm, digest_type, digest}),
    do: {key_tag, algorithm, digest_type, digest}

  defp decode_ds_data(<<key_tag::16, algorithm::8, digest_type::8, digest::binary>>),
    do: {key_tag, algorithm, digest_type, digest}

  defp decode_dnskey_data({flags, protocol, algorithm, public_key}),
    do: {flags, protocol, algorithm, public_key}

  defp decode_dnskey_data(<<flags::16, protocol::8, algorithm::8, public_key::binary>>),
    do: {flags, protocol, algorithm, public_key}

  defp decode_tlsa_data({usage, selector, matching_type, association_data}),
    do: {usage, selector, matching_type, association_data}

  defp decode_tlsa_data(<<usage::8, selector::8, matching_type::8, association_data::binary>>),
    do: {usage, selector, matching_type, association_data}

  defp rr_ip(rr) do
    rr
    |> rr_data()
    |> :inet.ntoa()
    |> to_string()
  end

  defp record_ip(%{content: content}), do: parse_ip!(content)

  defp parse_ip!(content) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(content))
    ip
  end

  defp txt_content(content) when is_list(content) and content != [] and is_list(hd(content)),
    do: Enum.map_join(content, "", &to_string/1)

  defp txt_content(content), do: to_string(content)

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp valid_upstream_response?(query, packet) do
    with <<id::16, flags::16, _rest::binary>> <- packet,
         true <- id == query.id,
         true <- (flags &&& 0x8000) != 0,
         {:ok, response_query} <- Packet.decode_question(packet),
         true <- normalize_name(response_query.qname) == normalize_name(query.qname),
         true <- response_query.qtype == query.qtype do
      true
    else
      _ -> false
    end
  end

  defp authentic_data?(<<_id::16, flags::16, _rest::binary>>), do: (flags &&& 0x0020) != 0
  defp authentic_data?(_), do: false

  defp cacheable_rcode?(rcode), do: rcode in [:noerror, :nxdomain]

  defp within_bailiwick?(_name, []), do: false

  defp within_bailiwick?(name, delegated_names) do
    Enum.any?(delegated_names, fn domain ->
      name == domain or String.ends_with?(name, "." <> domain)
    end)
  end
end
