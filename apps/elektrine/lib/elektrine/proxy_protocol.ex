defmodule Elektrine.ProxyProtocol do
  @moduledoc """
  PROXY protocol v1 parser for TCP services behind a proxy.

  The PROXY protocol allows proxies to pass the real client IP address
  to backend services over TCP connections for services like IMAP, SMTP,
  and POP3.

  Format: PROXY TCP4 <client_ip> <proxy_ip> <client_port> <proxy_port>\r\n
  Example: PROXY TCP4 192.168.1.1 172.16.17.162 12345 143\r\n

  Reference: https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt
  """

  import Bitwise
  require Logger

  @doc """
  Reads and parses the PROXY protocol header from a TCP socket.

  Returns `{:ok, client_ip_string}` if PROXY header is present and valid.
  Returns `{:ok, peer_ip_string}` if no PROXY header (falls back to peer IP).
  Returns `{:error, reason}` if the connection cannot be read.

  ## Examples

      iex> {:ok, socket} = :gen_tcp.accept(listen_socket)
      iex> {:ok, client_ip} = Elektrine.ProxyProtocol.parse_client_ip(socket)
      iex> client_ip
      "192.168.1.1"
  """
  def parse_client_ip(socket, opts \\ []) do
    # Get the peer IP as fallback
    {peer_ip, peer_ip_string} =
      case :inet.peername(socket) do
        {:ok, {ip, _port}} ->
          {ip, :inet.ntoa(ip) |> to_string()}

        {:error, _} ->
          {nil, "unknown"}
      end

    # Try to read the PROXY protocol header with a short timeout (1 second)
    # The header should be sent immediately by the proxy
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        line = to_string(data)

        if String.starts_with?(line, "PROXY ") do
          if trusted_proxy_peer?(peer_ip, opts) do
            parse_proxy_header(line, peer_ip_string)
          else
            Logger.warning("Ignoring PROXY protocol header from untrusted peer #{peer_ip_string}")
            {:ok, peer_ip_string, line}
          end
        else
          # No PROXY header - this is the actual client data
          # We need to "unread" this data by putting it back in the buffer
          # Since we can't do that with :gen_tcp, we'll return the peer IP
          # and the caller needs to handle the first line of data
          Logger.warning("Expected PROXY protocol header but got: #{String.slice(line, 0..50)}")
          {:ok, peer_ip_string, line}
        end

      {:error, :timeout} ->
        # No data received - likely no PROXY protocol, use peer IP
        {:ok, peer_ip_string, nil}

      {:error, :closed} ->
        # Connection closed before sending data - likely health check or PROXY not enabled
        {:error, :closed}

      {:error, reason} ->
        # Other errors (unlikely)
        {:error, reason}
    end
  end

  # Parses a PROXY protocol v1 header line.
  # Format: PROXY TCP4 <client_ip> <proxy_ip> <client_port> <proxy_port>\r\n
  # Returns the client IP if valid, or the fallback IP if parsing fails.
  defp parse_proxy_header(line, fallback_ip) do
    line = String.trim(line)

    case String.split(line, " ") do
      ["PROXY", "TCP4", client_ip, _proxy_ip, _client_port, _proxy_port] ->
        {:ok, client_ip, nil}

      ["PROXY", "TCP6", client_ip, _proxy_ip, _client_port, _proxy_port] ->
        {:ok, client_ip, nil}

      ["PROXY", "UNKNOWN" | _rest] ->
        {:ok, fallback_ip, nil}

      _ ->
        Logger.warning("Invalid PROXY protocol header: #{line}")
        {:ok, fallback_ip, line}
    end
  end

  defp trusted_proxy_peer?(ip, opts) when is_tuple(ip) do
    opts
    |> Keyword.get(:trusted_proxy_cidrs, configured_trusted_proxy_cidrs())
    |> Enum.map(&parse_cidr/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&ip_in_cidr?(ip, &1))
  end

  defp trusted_proxy_peer?(_, _), do: false

  defp configured_trusted_proxy_cidrs do
    Application.get_env(
      :elektrine,
      :proxy_protocol_trusted_cidrs,
      Application.get_env(:elektrine, :trusted_proxy_cidrs, [])
    )
  end

  defp parse_cidr(value) when is_binary(value) do
    value = String.trim(value)

    {ip_string, prefix_string} =
      case String.split(value, "/", parts: 2) do
        [ip, prefix] -> {ip, prefix}
        [ip] -> {ip, nil}
      end

    with {:ok, ip} <- :inet.parse_address(String.to_charlist(ip_string)),
         max_bits <- ip_max_bits(ip),
         {:ok, prefix} <- parse_prefix(prefix_string, max_bits) do
      {ip, prefix}
    else
      _ -> nil
    end
  end

  defp parse_cidr(_), do: nil

  defp parse_prefix(nil, max_bits), do: {:ok, max_bits}

  defp parse_prefix(value, max_bits) do
    case Integer.parse(value) do
      {prefix, ""} when prefix >= 0 and prefix <= max_bits -> {:ok, prefix}
      _ -> :error
    end
  end

  defp ip_in_cidr?(ip, {network, prefix}) do
    ip_max_bits(ip) == ip_max_bits(network) and
      ip_to_integer(ip) >>> (ip_max_bits(ip) - prefix) ==
        ip_to_integer(network) >>> (ip_max_bits(network) - prefix)
  end

  defp ip_max_bits(ip) when tuple_size(ip) == 4, do: 32
  defp ip_max_bits(ip) when tuple_size(ip) == 8, do: 128

  defp ip_to_integer(ip) when tuple_size(ip) == 4 do
    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn octet, acc -> (acc <<< 8) + octet end)
  end

  defp ip_to_integer(ip) when tuple_size(ip) == 8 do
    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, acc -> (acc <<< 16) + segment end)
  end
end
