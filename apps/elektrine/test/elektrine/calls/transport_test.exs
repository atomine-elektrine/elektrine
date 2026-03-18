defmodule Elektrine.Calls.TransportTest do
  use ExUnit.Case, async: true

  alias Elektrine.Calls.Transport

  test "descriptor_for_user/2 includes configured static ice servers" do
    descriptor = Transport.descriptor_for_user(42, 99)

    assert descriptor["mode"] in ["mesh", "sfu"]
    assert is_list(descriptor["ice_servers"])

    assert Enum.any?(descriptor["ice_servers"], fn server ->
             server["urls"] == ["stun:stun.l.google.com:19302"]
           end)
  end

  test "descriptor_for_user/2 appends dynamic turn credentials when configured" do
    original = Application.get_env(:elektrine, :webrtc, [])

    Application.put_env(
      :elektrine,
      :webrtc,
      Keyword.merge(original,
        turn_shared_secret: "test-secret",
        turn_uris: ["turn:turn.example.com:3478?transport=udp"],
        turn_username_ttl_seconds: 600
      )
    )

    on_exit(fn -> Application.put_env(:elektrine, :webrtc, original) end)

    descriptor =
      Transport.descriptor_for_user(7, 11, now: DateTime.from_unix!(1_700_000_000))

    turn_server =
      Enum.find(descriptor["ice_servers"], fn server ->
        server["urls"] == ["turn:turn.example.com:3478?transport=udp"]
      end)

    assert %{"username" => username, "credential" => credential} = turn_server
    assert username == "1700000600:7:11"
    assert is_binary(credential) and credential != ""
  end
end
