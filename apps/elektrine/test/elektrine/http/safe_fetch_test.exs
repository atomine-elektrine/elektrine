defmodule Elektrine.HTTP.SafeFetchTest do
  use ExUnit.Case, async: true

  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Security.URLValidator

  test "resolve_address/1 resolves private IP literals" do
    assert {:ok, {127, 0, 0, 1}} = URLValidator.resolve_address("127.0.0.1")
  end

  test "allow_private_network bypasses private IP rejection while preserving pinned resolution" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    request = Finch.build(:get, "http://127.0.0.1:#{port}/xrpc/test")

    assert {:error, :private_ip} =
             SafeFetch.request(request, Elektrine.Finch, receive_timeout: 100)

    assert {:error, reason} =
             SafeFetch.request(request, Elektrine.Finch,
               allow_private_network: true,
               pool_timeout: 100,
               receive_timeout: 100
             )

    refute reason == :private_ip
  end
end
