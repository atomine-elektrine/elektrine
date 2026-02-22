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

  @spec client_ip_tuple(Plug.Conn.t()) :: ip_tuple() | nil
  def client_ip_tuple(conn) do
    remote_ip = conn.remote_ip

    cond do
      # Fly always injects fly-client-ip for external HTTP traffic. Use it even when
      # trusted proxy CIDRs are not configured to avoid collapsing all clients to a
      # shared edge IP.
      running_on_fly?() and header_ip(conn, "fly-client-ip") ->
        header_ip(conn, "fly-client-ip")

      trusted_proxy?(remote_ip) ->
        forwarded_ip(conn) || remote_ip

      true ->
        remote_ip
    end
  end

  @spec trusted_proxy?(ip_tuple() | nil) :: boolean()
  def trusted_proxy?(ip) when is_tuple(ip) do
    trusted_proxy_cidrs()
    |> Enum.any?(&ip_in_cidr?(ip, &1))
  end

  def trusted_proxy?(_), do: false

  defp forwarded_ip(conn) do
    with nil <- header_ip(conn, "cf-connecting-ip"),
         nil <- x_forwarded_for_ip(conn),
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
        value
        |> String.split(",")
        |> Enum.map(&parse_ip_string/1)
        |> Enum.find_value(fn
          {:ok, ip} -> ip
          _ -> nil
        end)
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

  defp running_on_fly? do
    case System.get_env("FLY_APP_NAME") do
      nil -> false
      "" -> false
      _ -> true
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
            {ip_tuple, max_prefix(ip_tuple)}

          _ ->
            nil
        end

      [ip, prefix] ->
        with {:ok, ip_tuple} <- parse_ip_string(ip),
             {prefix_int, ""} <- Integer.parse(prefix),
             true <- valid_prefix?(ip_tuple, prefix_int) do
          {ip_tuple, prefix_int}
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

  defp format_ip(nil), do: "unknown"
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
end
