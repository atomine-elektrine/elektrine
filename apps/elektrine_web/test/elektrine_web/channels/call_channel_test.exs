defmodule ElektrineWeb.CallChannelTest do
  use ElektrineWeb.ChannelCase

  alias Elektrine.AccountsFixtures
  alias Elektrine.Calls.Call
  alias Elektrine.Messaging.{ChatConversation, ChatConversationMember, FederationCallSession}
  alias Elektrine.PubSubTopics
  alias Elektrine.Repo
  alias ElektrineWeb.UserSocket

  setup do
    caller = AccountsFixtures.user_fixture()
    callee = AccountsFixtures.user_fixture()

    call =
      %Call{}
      |> Call.changeset(%{
        caller_id: caller.id,
        callee_id: callee.id,
        call_type: "audio",
        status: "initiated"
      })
      |> Repo.insert!()

    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user socket", user_socket_claims(caller))
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    {:ok, _join_payload, socket} =
      subscribe_and_join(socket, ElektrineWeb.CallChannel, "call:#{call.id}")

    %{socket: socket}
  end

  test "accepts valid ICE candidates", %{socket: socket} do
    ref = push(socket, "ice_candidate", %{"candidate" => valid_candidate()})
    assert_reply ref, :ok
  end

  test "rejects oversized ICE candidates", %{socket: socket} do
    oversized_candidate =
      Map.put(valid_candidate(), "candidate", String.duplicate("a", 4_097))

    ref = push(socket, "ice_candidate", %{"candidate" => oversized_candidate})
    assert_reply ref, :error, %{reason: "invalid_candidate"}
  end

  test "rejects malformed ICE payloads", %{socket: socket} do
    ref = push(socket, "ice_candidate", %{"candidate" => "invalid"})
    assert_reply ref, :error, %{reason: "invalid_candidate"}
  end

  test "joins a federated call session and forwards remote signaling" do
    user = AccountsFixtures.user_fixture()

    conversation =
      %ChatConversation{}
      |> ChatConversation.dm_changeset(%{
        creator_id: user.id,
        name: "@remote@peer.example",
        federated_source: "arblarg:dm:handle:remote@peer.example"
      })
      |> Repo.insert!()

    ChatConversationMember.add_member_changeset(conversation.id, user.id, "member")
    |> Repo.insert!()

    session =
      %FederationCallSession{}
      |> FederationCallSession.changeset(%{
        conversation_id: conversation.id,
        local_user_id: user.id,
        federated_call_id: "https://peer.example/_arblarg/calls/test-call",
        origin_domain: "peer.example",
        remote_domain: "peer.example",
        remote_handle: "remote@peer.example",
        remote_actor: %{
          "handle" => "remote@peer.example",
          "username" => "remote",
          "domain" => "peer.example"
        },
        call_type: "audio",
        direction: "inbound",
        status: "active"
      })
      |> Repo.insert!()

    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user socket", user_socket_claims(user))
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    {:ok, _join_payload, joined_socket} =
      subscribe_and_join(socket, ElektrineWeb.CallChannel, "call:#{session.id}")

    expected_user_id = user.id

    assert_push "presence_state", %{}
    assert_push "joined", %{user_id: ^expected_user_id}

    PubSubTopics.broadcast(PubSubTopics.call(session.id), :federated_peer_ready, %{})
    assert_push "peer_ready", %{user_id: ^expected_user_id}

    offer = %{"type" => "offer", "sdp" => "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"}

    PubSubTopics.broadcast(PubSubTopics.call(session.id), :federated_call_signal, %{
      kind: "offer",
      payload: offer
    })

    assert_push "offer", %{sdp: ^offer}
    assert joined_socket.topic == "call:#{session.id}"
  end

  defp valid_candidate do
    %{
      "candidate" =>
        "candidate:842163049 1 udp 1677729535 192.168.1.2 56143 typ srflx raddr 0.0.0.0 rport 0",
      "sdpMid" => "0",
      "sdpMLineIndex" => 0
    }
  end

  defp user_socket_claims(user) do
    %{
      "user_id" => user.id,
      "password_changed_at" => DateTime.to_unix(user.last_password_change, :second),
      "auth_valid_after" =>
        case user.auth_valid_after do
          %DateTime{} = valid_after -> DateTime.to_unix(valid_after, :second)
          _ -> 0
        end
    }
  end
end
