defmodule Elektrine.ProxyProtocol do
  @moduledoc """
  PROXY protocol v1 parser for Fly.io TCP services.

  The PROXY protocol allows proxies to pass the real client IP address
  to backend services over TCP connections. Fly.io uses this for services
  like IMAP, SMTP, and POP3.

  Format: PROXY TCP4 <client_ip> <proxy_ip> <client_port> <proxy_port>\r\n
  Example: PROXY TCP4 192.168.1.1 172.16.17.162 12345 143\r\n

  Reference: https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt
  """

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
  def parse_client_ip(socket) do
    # Get the peer IP as fallback
    peer_ip =
      case :inet.peername(socket) do
        {:ok, {ip, _port}} ->
          :inet.ntoa(ip) |> to_string()

        {:error, _} ->
          "unknown"
      end

    # Try to read the PROXY protocol header with a short timeout (1 second)
    # The header should be sent immediately by the proxy
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        line = to_string(data)

        if String.starts_with?(line, "PROXY ") do
          parse_proxy_header(line, peer_ip)
        else
          # No PROXY header - this is the actual client data
          # We need to "unread" this data by putting it back in the buffer
          # Since we can't do that with :gen_tcp, we'll return the peer IP
          # and the caller needs to handle the first line of data
          Logger.warning("Expected PROXY protocol header but got: #{String.slice(line, 0..50)}")
          {:ok, peer_ip, line}
        end

      {:error, :timeout} ->
        # No data received - likely no PROXY protocol, use peer IP
        {:ok, peer_ip, nil}

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
end
