defmodule Elektrine.VPN.WireGuardAdapter do
  @moduledoc false

  def current_peer_keys(interface) do
    with {:ok, output} <- run_wg(["show", interface, "peers"]) do
      {:ok,
       output
       |> String.split("\n", trim: true)
       |> MapSet.new()}
    end
  end

  def sync_peer(interface, peer) do
    run_wg([
      "set",
      interface,
      "peer",
      peer.public_key,
      "allowed-ips",
      peer.allocated_ip,
      "persistent-keepalive",
      to_string(peer.persistent_keepalive || 25)
    ])
  end

  def remove_peer(interface, public_key) do
    run_wg(["set", interface, "peer", public_key, "remove"])
  end

  def peer_stats(interface) do
    with {:ok, output} <- run_wg(["show", interface, "dump"]) do
      {:ok, parse_dump(output)}
    end
  end

  def parse_dump(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.reduce([], fn line, acc ->
      case String.split(line, "\t") do
        [
          public_key,
          _psk,
          _endpoint,
          _allowed_ips,
          last_handshake,
          bytes_received,
          bytes_sent,
          _keepalive
        ]
        when public_key != "" ->
          [
            %{
              public_key: public_key,
              last_handshake: parse_handshake(last_handshake),
              bytes_received: parse_integer(bytes_received),
              bytes_sent: parse_integer(bytes_sent)
            }
            | acc
          ]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp run_wg(args) do
    case System.cmd("wg", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {:command_failed, Exception.message(e)}}
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp parse_handshake(value) do
    case parse_integer(value) do
      0 -> nil
      epoch -> DateTime.from_unix!(epoch) |> DateTime.to_iso8601()
    end
  end
end
