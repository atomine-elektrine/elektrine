defmodule Elektrine.DNS.RecursiveTransport do
  @moduledoc false

  def exchange_udp(ip, port, packet, timeout) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        result =
          with :ok <- :gen_udp.send(socket, ip, port, packet),
               {:ok, {host, recv_port, response}} <- :gen_udp.recv(socket, 0, timeout),
               true <- host == ip and recv_port == port do
            {:ok, response}
          else
            {:error, _reason} = error -> error
            false -> {:error, :unexpected_upstream}
          end

        :gen_udp.close(socket)
        result

      {:error, _reason} = error ->
        error
    end
  end

  def exchange_tcp(ip, port, packet, timeout) do
    case :gen_tcp.connect(ip, port, [:binary, active: false, packet: 0], timeout) do
      {:ok, socket} ->
        result =
          with :ok <- :gen_tcp.send(socket, <<byte_size(packet)::16, packet::binary>>),
               {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, timeout) do
            :gen_tcp.recv(socket, length, timeout)
          else
            {:error, _reason} = error -> error
          end

        :gen_tcp.close(socket)
        result

      {:error, _reason} = error ->
        error
    end
  end
end
