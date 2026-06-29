import Config

parse_bool_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] ->
      true

    value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] ->
      false

    _ ->
      default
  end
end

parse_int_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {int, ""} when int > 0 -> int
        _ -> default
      end
  end
end

parse_dns_endpoint = fn value ->
  trimmed = String.trim(value)

  case Regex.run(~r/^\[(.+)\](?::(\d+))?$/, trimmed) do
    [_, host, port] ->
      with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)),
           {parsed_port, ""} <- Integer.parse(port) do
        {:ok, {ip, parsed_port}}
      else
        _ -> :error
      end

    [_, host] ->
      with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)) do
        {:ok, {ip, 53}}
      else
        _ -> :error
      end

    nil ->
      case String.split(trimmed, ":", parts: 2) do
        [host, port] ->
          with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)),
               {parsed_port, ""} <- Integer.parse(port) do
            {:ok, {ip, parsed_port}}
          else
            _ -> :error
          end

        [host] ->
          with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)) do
            {:ok, {ip, 53}}
          else
            _ -> :error
          end

        _ ->
          :error
      end
  end
end

parse_dns_endpoints = fn value ->
  value
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.map(parse_dns_endpoint)
  |> Enum.flat_map(fn
    {:ok, endpoint} -> [endpoint]
    :error -> []
  end)
  |> Enum.uniq()
end

dns_config = Application.get_env(:elektrine, :dns, [])

dns_nameservers =
  case System.get_env("DNS_NAMESERVERS") do
    nil -> Keyword.get(dns_config, :nameservers, [])
    "" -> []
    value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

dns_soa_rname =
  case System.get_env("DNS_SOA_RNAME") do
    nil -> Keyword.get(dns_config, :soa_rname)
    "" -> nil
    value -> String.trim(value)
  end

dns_recursive_allow_cidrs =
  case System.get_env("DNS_RECURSIVE_ALLOW_CIDRS") do
    nil -> Keyword.get(dns_config, :recursive_allow_cidrs, [])
    "" -> []
    value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

dns_recursive_upstreams =
  case System.get_env("DNS_RECURSIVE_UPSTREAMS") do
    nil -> Keyword.get(dns_config, :recursive_upstreams, [])
    "" -> []
    value -> parse_dns_endpoints.(value)
  end

dns_edge_proxy_ipv4_addresses =
  case System.get_env("DNS_EDGE_PROXY_IPV4_ADDRESSES") do
    nil ->
      Keyword.get(dns_config, :edge_proxy_ipv4_addresses, [])

    "" ->
      []

    value ->
      value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

dns_edge_proxy_ipv6_addresses =
  case System.get_env("DNS_EDGE_PROXY_IPV6_ADDRESSES") do
    nil ->
      Keyword.get(dns_config, :edge_proxy_ipv6_addresses, [])

    "" ->
      []

    value ->
      value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

dns_edge_proxy_hostname =
  case System.get_env("DNS_EDGE_PROXY_HOSTNAME") do
    nil ->
      Keyword.get(dns_config, :edge_proxy_hostname)

    "" ->
      nil

    value ->
      value |> String.trim() |> String.trim_trailing(".") |> String.downcase()
  end

config :elektrine, :dns,
  authority_enabled:
    parse_bool_env.(
      "DNS_AUTHORITY_ENABLED",
      Keyword.get(dns_config, :authority_enabled, false)
    ),
  recursive_enabled:
    parse_bool_env.(
      "DNS_RECURSIVE_ENABLED",
      Keyword.get(dns_config, :recursive_enabled, false)
    ),
  edge_proxy_enabled:
    parse_bool_env.(
      "DNS_EDGE_PROXY_ENABLED",
      Keyword.get(dns_config, :edge_proxy_enabled, true)
    ),
  zone_cache_refresh_interval_ms:
    parse_int_env.(
      "DNS_ZONE_CACHE_REFRESH_INTERVAL_MS",
      Keyword.get(dns_config, :zone_cache_refresh_interval_ms, 300_000)
    ),
  nameservers: dns_nameservers,
  soa_rname: dns_soa_rname,
  recursive_upstreams: dns_recursive_upstreams,
  recursive_allow_cidrs: dns_recursive_allow_cidrs,
  edge_proxy_ipv4_addresses: dns_edge_proxy_ipv4_addresses,
  edge_proxy_ipv6_addresses: dns_edge_proxy_ipv6_addresses,
  edge_proxy_hostname: dns_edge_proxy_hostname,
  max_udp_payload:
    parse_int_env.(
      "DNS_MAX_UDP_PAYLOAD",
      Keyword.get(dns_config, :max_udp_payload, 1232)
    ),
  rate_limit_window_ms:
    parse_int_env.(
      "DNS_RATE_LIMIT_WINDOW_MS",
      Keyword.get(dns_config, :rate_limit_window_ms, 1000)
    ),
  udp_rate_limit_per_window:
    parse_int_env.(
      "DNS_UDP_RATE_LIMIT_PER_WINDOW",
      Keyword.get(dns_config, :udp_rate_limit_per_window, 200)
    ),
  tcp_rate_limit_per_window:
    parse_int_env.(
      "DNS_TCP_RATE_LIMIT_PER_WINDOW",
      Keyword.get(dns_config, :tcp_rate_limit_per_window, 50)
    ),
  udp_max_inflight:
    parse_int_env.(
      "DNS_UDP_MAX_INFLIGHT",
      Keyword.get(dns_config, :udp_max_inflight, 1024)
    ),
  tcp_max_inflight:
    parse_int_env.(
      "DNS_TCP_MAX_INFLIGHT",
      Keyword.get(dns_config, :tcp_max_inflight, 256)
    ),
  udp_port:
    parse_int_env.(
      "DNS_UDP_PORT",
      Keyword.get(dns_config, :udp_port, 5300)
    ),
  tcp_port:
    parse_int_env.(
      "DNS_TCP_PORT",
      Keyword.get(dns_config, :tcp_port, 5300)
    ),
  recursive_timeout:
    parse_int_env.(
      "DNS_RECURSIVE_TIMEOUT_MS",
      Keyword.get(dns_config, :recursive_timeout, 3000)
    )
