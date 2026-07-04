defmodule ElektrineWeb.VoiceChannelTest do
  use ElektrineWeb.ChannelCase

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias ElektrineWeb.UserSocket
  alias ElektrineWeb.VoiceChannel

  setup do
    owner = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()

    {:ok, server} = Messaging.create_server(owner.id, %{name: "voice-hub", is_public: true})
    {:ok, _member} = Messaging.join_server(server.id, member.id)

    {:ok, voice} =
      Messaging.create_server_channel(server.id, owner.id, %{
        name: "hangout",
        type: "voice_channel"
      })

    %{owner: owner, member: member, server: server, voice: voice}
  end

  defp connect_user(user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user socket", user_socket_claims(user))
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  defp join_voice(user, voice) do
    user
    |> connect_user()
    |> subscribe_and_join(VoiceChannel, "voice:#{voice.id}")
  end

  test "members join and are tracked in presence", %{owner: owner, voice: voice} do
    assert {:ok, _payload, socket} = join_voice(owner, voice)

    assert_push "presence_state", %{}

    owner_key = to_string(owner.id)
    presence = ElektrineWeb.Presence.list("voice:#{voice.id}")

    assert %{metas: [meta | _rest]} = presence[owner_key]
    assert meta.user_id == owner.id
    assert meta.muted == false
    assert is_integer(meta.joined_at)
    assert socket.assigns.conversation_id == voice.id
  end

  test "non-members are rejected", %{voice: voice} do
    outsider = AccountsFixtures.user_fixture()

    assert {:error, %{reason: "unauthorized"}} = join_voice(outsider, voice)
  end

  test "text channels cannot be joined as voice", %{owner: owner, server: server} do
    {:ok, loaded} = Messaging.get_server(server.id, owner.id)
    text_channel = Enum.find(loaded.channels, &(&1.type == "channel"))

    socket = connect_user(owner)

    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(socket, VoiceChannel, "voice:#{text_channel.id}")
  end

  test "relays signals only to the targeted peer", %{owner: owner, member: member, voice: voice} do
    {:ok, _payload, owner_socket} = join_voice(owner, voice)
    {:ok, _payload, _member_socket} = join_voice(member, voice)

    offer = %{"type" => "offer", "sdp" => "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"}

    ref =
      push(owner_socket, "signal", %{"to" => member.id, "kind" => "offer", "payload" => offer})

    assert_reply ref, :ok

    owner_id = owner.id
    assert_push "signal", %{from: ^owner_id, kind: "offer", payload: ^offer}
    refute_push "signal", %{from: ^owner_id, kind: "offer", payload: ^offer}
  end

  test "rejects malformed signals", %{owner: owner, member: member, voice: voice} do
    {:ok, _payload, socket} = join_voice(owner, voice)

    bad_offer = %{"type" => "offer", "sdp" => "not-sdp"}

    ref =
      push(socket, "signal", %{"to" => member.id, "kind" => "offer", "payload" => bad_offer})

    assert_reply ref, :error, %{reason: "invalid_signal"}

    ref = push(socket, "signal", %{"to" => member.id, "kind" => "warp", "payload" => %{}})
    assert_reply ref, :error, %{reason: "invalid_signal"}
  end

  test "set_muted updates presence metadata", %{owner: owner, voice: voice} do
    {:ok, _payload, socket} = join_voice(owner, voice)

    ref = push(socket, "set_muted", %{"muted" => true})
    assert_reply ref, :ok

    assert %{metas: [%{muted: true} | _rest]} =
             ElektrineWeb.Presence.list("voice:#{voice.id}")[to_string(owner.id)]
  end

  test "enforces the occupancy cap", %{owner: owner, member: member, voice: voice} do
    original = Application.get_env(:elektrine, :voice_channels)
    Application.put_env(:elektrine, :voice_channels, max_occupants: 1)

    on_exit(fn ->
      if original do
        Application.put_env(:elektrine, :voice_channels, original)
      else
        Application.delete_env(:elektrine, :voice_channels)
      end
    end)

    assert {:ok, _payload, _socket} = join_voice(owner, voice)
    assert {:error, %{reason: "channel_full"}} = join_voice(member, voice)
  end

  test "rejects a second connection from the same user", %{owner: owner, voice: voice} do
    assert {:ok, _payload, _socket} = join_voice(owner, voice)
    assert {:error, %{reason: "already_joined"}} = join_voice(owner, voice)
  end

  defp user_socket_claims(user) do
    %{
      "user_id" => user.id,
      "password_changed_at" => unix_or_zero(user.last_password_change),
      "auth_valid_after" => unix_or_zero(user.auth_valid_after)
    }
  end

  defp unix_or_zero(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :second)
  defp unix_or_zero(_other), do: 0
end
