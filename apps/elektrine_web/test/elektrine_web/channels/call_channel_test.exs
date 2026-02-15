defmodule ElektrineWeb.CallChannelTest do
  use ElektrineWeb.ChannelCase

  alias Elektrine.AccountsFixtures
  alias Elektrine.Calls.Call
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

    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user socket", caller.id)
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

  defp valid_candidate do
    %{
      "candidate" =>
        "candidate:842163049 1 udp 1677729535 192.168.1.2 56143 typ srflx raddr 0.0.0.0 rport 0",
      "sdpMid" => "0",
      "sdpMLineIndex" => 0
    }
  end
end
