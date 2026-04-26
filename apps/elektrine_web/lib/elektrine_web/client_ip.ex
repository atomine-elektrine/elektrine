defmodule ElektrineWeb.ClientIP do
  @moduledoc """
  Resolves client IP addresses safely when running behind reverse proxies.

  Forwarded headers are honored only when the direct remote peer is in
  `:trusted_proxy_cidrs`. Otherwise, `conn.remote_ip` is used.
  """

  import Plug.Conn, only: [get_req_header: 2]
  import Bitwise

  @type ip_tuple :: :inet.ip4_address() | :inet.ip6_address()
  @type cidr :: {ip_tuple(), non_neg_integer()}

  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    conn
    |> client_ip_tuple()
    |> format_ip()
  end

  @spec rate_limit_ip(Plug.Conn.t()) :: String.t()
  def rate_limit_ip(conn) do
    conn
    |> client_ip()
    |> normalize_ipv6_subnet()
  end

  @spec client_ip_tuple(Plug.Conn.t()) :: ip_tuple() | nil
  def client_ip_tuple(conn) do
    remote_ip = normalize_ip_tuple(conn.remote_ip)

    if trusted_proxy?(remote_ip) do
      forwarded_ip(conn) || remote_ip
    else
      remote_ip
    end
  end

  @spec forwarded_as_https?(Plug.Conn.t()) :: boolean()
  def forwarded_as_https?(conn) do
    header_forwarded_as_https?(conn) and trusted_proxy?(conn.remote_ip)
  end

  @spec trusted_proxy?(ip_tuple() | nil) :: boolean()
  def trusted_proxy?(ip) when is_tuple(ip) do
    ip = normalize_ip_tuple(ip)

    trusted_proxy_cidrs()
    |> Enum.any?(&ip_in_cidr?(ip, &1))
  end

  def trusted_proxy?(_), do: false

  @spec ip_in_cidrs?(ip_tuple() | nil, [String.t()]) :: boolean()
  def ip_in_cidrs?(ip, cidrs) when is_tuple(ip) and is_list(cidrs) do
    ip = normalize_ip_tuple(ip)

    cidrs
    |> Enum.map(&parse_cidr/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&ip_in_cidr?(ip, &1))
  end

  def ip_in_cidrs?(_, _), do: false

  defp forwarded_ip(conn) do
    with nil <- x_forwarded_for_ip(conn),
         nil <- header_ip(conn, "x-real-ip") do
      nil
    else
      ip -> ip
    end
  end

  defp x_forwarded_for_ip(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> List.first()
    |> case do
      nil ->
        nil

      value ->
        parsed_ips =
          value
          |> String.split(",")
          |> Enum.map(&parse_ip_string/1)
          |> Enum.flat_map(fn
            {:ok, ip} -> [ip]
            _ -> []
          end)

        Enum.find(parsed_ips, &public_client_ip_candidate?/1) || List.first(parsed_ips)
    end
  end

  defp header_ip(conn, header_name) do
    conn
    |> get_req_header(header_name)
    |> List.first()
    |> parse_ip_string()
    |> case do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp parse_ip_string(value) when is_binary(value) do
    candidate =
      value
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")
      |> strip_brackets_and_port()
      |> strip_ipv4_port()

    case :inet.parse_address(String.to_charlist(candidate)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp parse_ip_string(_), do: :error

  defp strip_brackets_and_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [ip, _] -> ip
      _ -> rest
    end
  end

  defp strip_brackets_and_port(value), do: value

  defp strip_ipv4_port(value) do
    if Regex.match?(~r/^\d{1,3}(?:\.\d{1,3}){3}:\d+$/, value) do
      [ip | _] = String.split(value, ":", parts: 2)
      ip
    else
      value
    end
  end

  defp trusted_proxy_cidrs do
    Application.get_env(:elektrine, :trusted_proxy_cidrs, [])
    |> Enum.map(&parse_cidr/1)
    |> Enum.reject(&is_nil/1)
  end

  defp header_forwarded_as_https?(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [value | _] ->
        value
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> String.downcase() == "https"

      _ ->
        false
    end
  end

  defp parse_cidr(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split("/", parts: 2)
    |> case do
      [ip] ->
        case parse_ip_string(ip) do
          {:ok, ip_tuple} ->
            normalized_ip = normalize_ip_tuple(ip_tuple)
            {normalized_ip, max_prefix(normalized_ip)}

          _ ->
            nil
        end

      [ip, prefix] ->
        with {:ok, ip_tuple} <- parse_ip_string(ip),
             normalized_ip = normalize_ip_tuple(ip_tuple),
             {prefix_int, ""} <- Integer.parse(prefix),
             true <- valid_prefix?(normalized_ip, prefix_int) do
          {normalized_ip, prefix_int}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_cidr(_), do: nil

  defp max_prefix({_, _, _, _}), do: 32
  defp max_prefix({_, _, _, _, _, _, _, _}), do: 128

  defp valid_prefix?({_, _, _, _}, prefix), do: prefix >= 0 and prefix <= 32
  defp valid_prefix?({_, _, _, _, _, _, _, _}, prefix), do: prefix >= 0 and prefix <= 128
  defp valid_prefix?(_, _), do: false

  defp ip_in_cidr?(ip, {network, prefix}) do
    case {ip, network} do
      {{_, _, _, _} = ip4, {_, _, _, _} = net4} ->
        masked_equal?(ip_to_int(ip4), ip_to_int(net4), prefix, 32)

      {{_, _, _, _, _, _, _, _} = ip6, {_, _, _, _, _, _, _, _} = net6} ->
        masked_equal?(ip_to_int(ip6), ip_to_int(net6), prefix, 128)

      _ ->
        false
    end
  end

  defp masked_equal?(_ip, _network, 0, _bits), do: true

  defp masked_equal?(ip, network, prefix, bits) when prefix > 0 do
    shift = bits - prefix
    ip >>> shift == network >>> shift
  end

  defp ip_to_int({a, b, c, d}) do
    Enum.reduce([a, b, c, d], 0, fn part, acc -> (acc <<< 8) + part end)
  end

  defp ip_to_int({a, b, c, d, e, f, g, h}) do
    Enum.reduce([a, b, c, d, e, f, g, h], 0, fn part, acc -> (acc <<< 16) + part end)
  end

  defp public_client_ip_candidate?(ip) do
    case maybe_unwrap_mapped_ipv4(ip) do
      {10, _, _, _} -> false
      {a, b, _, _} when a == 100 and b >= 64 and b <= 127 -> false
      {127, _, _, _} -> false
      {169, 254, _, _} -> false
      {172, b, _, _} when b >= 16 and b <= 31 -> false
      {192, 168, _, _} -> false
      {0, 0, 0, 0} -> false
      {0, 0, 0, 1} -> false
      {_, _, _, _} -> true
      {0, 0, 0, 0, 0, 0, 0, 0} -> false
      {0, 0, 0, 0, 0, 0, 0, 1} -> false
      {a, _, _, _, _, _, _, _} when (a &&& 0xFE00) == 0xFC00 -> false
      {a, _, _, _, _, _, _, _} when (a &&& 0xFFC0) == 0xFE80 -> false
      {_, _, _, _, _, _, _, _} -> true
      _ -> false
    end
  end

  defp maybe_unwrap_mapped_ipv4({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    {g >>> 8, g &&& 0xFF, h >>> 8, h &&& 0xFF}
  end

  defp maybe_unwrap_mapped_ipv4(ip), do: ip

  defp normalize_ip_tuple({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    {g >>> 8, g &&& 0xFF, h >>> 8, h &&& 0xFF}
  end

  defp normalize_ip_tuple(ip), do: ip

  defp format_ip(nil), do: "unknown"

  defp format_ip(ip) when is_tuple(ip),
    do: ip |> normalize_ip_tuple() |> :inet.ntoa() |> to_string()

  defp normalize_ipv6_subnet(ip_string) when is_binary(ip_string) do
    if String.contains?(ip_string, ":") do
      hextets = String.split(ip_string, ":")

      normalized_hextets =
        if Enum.any?(hextets, &(&1 == "")) do
          parts_before = Enum.take_while(hextets, &(&1 != ""))
          parts_after = hextets |> Enum.drop_while(&(&1 != "")) |> Enum.drop(1)
          zeros_needed = 8 - length(parts_before) - length(parts_after)
          parts_before ++ List.duplicate("0", zeros_needed) ++ parts_after
        else
          hextets
        end

      normalized_hextets
      |> Enum.take(4)
      |> Enum.join(":")
      |> Kernel.<>("::/64")
    else
      ip_string
    end
  end

  defp normalize_ipv6_subnet(ip_string), do: ip_string
end
