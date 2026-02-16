defmodule Elektrine.Security.URLValidator do
  @moduledoc """
  URL validation for SSRF (Server-Side Request Forgery) protection.

  Validates URLs before making external HTTP requests to prevent
  access to internal networks, cloud metadata endpoints, and other
  sensitive resources.
  """

  import Bitwise

  @doc """
  Validates a URL for SSRF protection.

  Returns `:ok` if the URL is safe to fetch, or `{:error, reason}` if it should be blocked.

  ## Examples

      iex> URLValidator.validate("https://example.com")
      :ok

      iex> URLValidator.validate("http://127.0.0.1/admin")
      {:error, :private_ip}

      iex> URLValidator.validate("http://169.254.169.254/latest/meta-data/")
      {:error, :private_ip}
  """
  def validate(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{} = uri ->
        validate_uri(uri)

      _ ->
        {:error, :invalid_url}
    end
  end

  def validate(_), do: {:error, :invalid_url}

  defp validate_uri(%URI{scheme: scheme, host: host} = uri)
       when scheme in ["http", "https"] and is_binary(host) do
    with :ok <- validate_host(host),
         false <- is_dangerous_port?(uri) do
      :ok
    else
      true ->
        {:error, :dangerous_port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_uri(%URI{scheme: nil}), do: {:error, :missing_scheme}
  defp validate_uri(%URI{scheme: scheme}) when scheme not in ["http", "https"], do: {:error, :invalid_scheme}
  defp validate_uri(_), do: {:error, :invalid_url}

  defp validate_host(host) when is_binary(host) do
    normalized_host = normalize_host(host)

    cond do
      is_private_ip?(normalized_host) ->
        {:error, :private_ip}

      is_private_domain?(normalized_host) ->
        {:error, :private_domain}

      true ->
        case resolve_host_ips(normalized_host) do
          {:ok, ips} ->
            if Enum.any?(ips, &private_or_special_ip?/1) do
              {:error, :private_ip}
            else
              :ok
            end

          {:error, _} ->
            {:error, :unresolvable_host}
        end
    end
  end

  @doc """
  Validates a URL and raises on failure.
  """
  def validate!(url) do
    case validate(url) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "URL validation failed: #{reason}"
    end
  end

  @doc """
  Checks if a host is a private/internal IP address.
  """
  def is_private_ip?(host) when is_binary(host) do
    host = normalize_host(host)

    case parse_address(host) do
      {:ok, ip} ->
        private_or_special_ip?(ip)

      :error ->
        # Backwards-compatible hostname checks for known internal patterns.
        ipv4_private?(host) or
          ipv6_private?(host) or
          localhost?(host) or
          link_local?(host) or
          cloud_metadata?(host)
    end
  end

  def is_private_ip?(_), do: false

  defp normalize_host(host) do
    host
    |> String.downcase()
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split("%", parts: 2)
    |> List.first()
  end

  defp parse_address(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp resolve_host_ips(host) do
    case parse_address(host) do
      {:ok, ip} ->
        {:ok, [ip]}

      :error ->
        a_records = :inet_res.lookup(String.to_charlist(host), :in, :a)
        aaaa_records = :inet_res.lookup(String.to_charlist(host), :in, :aaaa)
        records = Enum.uniq(a_records ++ aaaa_records)

        if records == [] do
          {:error, :dns_resolution_failed}
        else
          {:ok, records}
        end
    end
  end

  defp private_or_special_ip?({a, b, c, d}) do
    ipv4_private_tuple?({a, b, c, d})
  end

  defp private_or_special_ip?({a, b, c, d, e, f, g, h}) do
    ipv6_private_tuple?({a, b, c, d, e, f, g, h})
  end

  defp private_or_special_ip?(_), do: true

  defp ipv4_private_tuple?({a, b, _c, _d}) do
    cond do
      # 10.0.0.0/8
      a == 10 ->
        true

      # 172.16.0.0/12
      a == 172 and b >= 16 and b <= 31 ->
        true

      # 192.168.0.0/16
      a == 192 and b == 168 ->
        true

      # 127.0.0.0/8 loopback
      a == 127 ->
        true

      # 0.0.0.0/8
      a == 0 ->
        true

      # 169.254.0.0/16 link-local
      a == 169 and b == 254 ->
        true

      # 100.64.0.0/10 CGNAT
      a == 100 and b >= 64 and b <= 127 ->
        true

      # 198.18.0.0/15 benchmarking
      a == 198 and b in [18, 19] ->
        true

      # 224.0.0.0/4 multicast/reserved
      a >= 224 ->
        true

      true ->
        false
    end
  end

  defp ipv6_private_tuple?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp ipv6_private_tuple?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  # IPv4-mapped IPv6 ::ffff:w.x.y.z
  defp ipv6_private_tuple?({0, 0, 0, 0, 0, 65_535, g, h}) do
    mapped_v4 = {g >>> 8, g &&& 0xFF, h >>> 8, h &&& 0xFF}
    ipv4_private_tuple?(mapped_v4)
  end

  defp ipv6_private_tuple?({a, _b, _c, _d, _e, _f, _g, _h}) do
    cond do
      # fc00::/7 unique-local
      (a &&& 0xFE00) == 0xFC00 ->
        true

      # fe80::/10 link-local
      (a &&& 0xFFC0) == 0xFE80 ->
        true

      # ff00::/8 multicast
      (a &&& 0xFF00) == 0xFF00 ->
        true

      true ->
        false
    end
  end

  defp ipv4_private?(host) do
    # 10.0.0.0/8
    # 172.16.0.0/12
    # 192.168.0.0/16
    # 127.0.0.0/8 (loopback)
    # 0.0.0.0/8
    # 100.64.0.0/10 (Carrier-grade NAT)
    # 169.254.0.0/16 (link-local)
    # 224.0.0.0/4 (multicast)
    String.starts_with?(host, "10.") or
      Regex.match?(~r/^172\.(1[6-9]|2[0-9]|3[0-1])\./, host) or
      String.starts_with?(host, "192.168.") or
      String.starts_with?(host, "127.") or
      String.starts_with?(host, "0.") or
      Regex.match?(~r/^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\./, host) or
      String.starts_with?(host, "169.254.") or
      multicast_ipv4?(host)
  end

  defp multicast_ipv4?(host) do
    case String.split(host, ".", parts: 2) do
      [first | _] ->
        case Integer.parse(first) do
          {n, ""} when n >= 224 and n <= 239 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp ipv6_private?(host) do
    # Remove brackets for IPv6
    host = String.trim(host, "[]")

    String.starts_with?(host, [
      # Loopback
      "::1",
      # Unique local addresses
      "fc00:",
      "fd00:",
      # Link-local
      "fe80:",
      # IPv4-mapped IPv6
      "::ffff:127.",
      "::ffff:10.",
      "::ffff:192.168.",
      "::ffff:169.254.",
      # Discard prefix
      "100::",
      # Documentation
      "2001:db8:"
    ])
  end

  defp localhost?(host) do
    host in [
      "localhost",
      "localhost.localdomain",
      "ip6-localhost",
      "ip6-loopback"
    ]
  end

  defp link_local?(host) do
    String.ends_with?(host, [
      ".local",
      ".localhost",
      ".internal",
      ".lan",
      ".home",
      ".corp",
      ".localdomain"
    ])
  end

  defp cloud_metadata?(host) do
    # AWS, GCP, Azure metadata endpoints
    host in [
      "169.254.169.254",
      "metadata.google.internal",
      "metadata",
      "169.254.170.2"
    ] or
      String.ends_with?(host, ".internal") or
      String.contains?(host, "metadata")
  end

  @doc """
  Checks if a domain is a private/internal domain.
  """
  def is_private_domain?(host) when is_binary(host) do
    host = String.downcase(host)

    String.ends_with?(host, [
      ".local",
      ".localhost",
      ".internal",
      ".lan",
      ".home",
      ".corp",
      ".localdomain",
      ".intranet",
      ".private"
    ]) or
      host in [
        "localhost",
        "localhost.localdomain",
        "broadcasthost",
        "ip6-localhost",
        "ip6-loopback",
        "ip6-localnet",
        "ip6-mcastprefix",
        "ip6-allnodes",
        "ip6-allrouters"
      ]
  end

  # Common internal service ports that should be blocked
  @dangerous_ports [
    22,
    23,
    25,
    110,
    143,
    445,
    3306,
    5432,
    6379,
    27017,
    9200,
    9300,
    11211,
    2379,
    2380
  ]

  defp is_dangerous_port?(%URI{port: nil}), do: false
  defp is_dangerous_port?(%URI{port: 80}), do: false
  defp is_dangerous_port?(%URI{port: 443}), do: false
  defp is_dangerous_port?(%URI{port: 8080}), do: false
  defp is_dangerous_port?(%URI{port: 8443}), do: false
  defp is_dangerous_port?(%URI{port: port}) when port in @dangerous_ports, do: true
  defp is_dangerous_port?(_), do: false
end
