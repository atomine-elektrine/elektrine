defmodule Elektrine.Messaging.FederationRemoteJoinTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Messaging.FederationMembershipState
  alias Elektrine.Repo

  describe "remote join moderation workflow" do
    test "lists and approves pending remote join requests for a local authoritative room" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "approval-hub"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "gated-room",
          description: "requires approval"
        })

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/alice",
          username: "alice",
          domain: "remote.example",
          display_name: "Alice",
          inbox_url: "https://remote.example/users/alice/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      %FederationMembershipState{}
      |> FederationMembershipState.changeset(%{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "invited",
        updated_at_remote: inserted_at,
        metadata: %{"join_request" => true, "reason" => "approval_required"}
      })
      |> Repo.insert!()

      assert [
               %{
                 remote_actor_id: remote_actor_id,
                 handle: "@alice@remote.example",
                 display_label: "Alice (@alice@remote.example)"
               }
             ] = Messaging.list_pending_remote_join_requests(channel.id)

      assert remote_actor_id == remote_actor.id

      assert {:ok, approved_request} =
               Messaging.approve_remote_join_request(channel.id, remote_actor.id, owner.id)

      assert approved_request.state == "active"

      assert %FederationMembershipState{} =
               membership_state =
               Repo.get_by(FederationMembershipState,
                 conversation_id: channel.id,
                 remote_actor_id: remote_actor.id
               )

      assert membership_state.state == "active"
      assert get_in(membership_state.metadata, ["join_request"]) == false
      assert get_in(membership_state.metadata, ["join_decision"]) == "accepted"
      assert Messaging.list_pending_remote_join_requests(channel.id) == []
    end

    test "declines pending remote join requests and removes them from the pending queue" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "approval-hub-decline"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "gated-room-decline",
          description: "requires approval"
        })

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://remote.example/users/bob",
          username: "bob",
          domain: "remote.example",
          display_name: "Bob",
          inbox_url: "https://remote.example/users/bob/inbox",
          public_key: "test-public-key"
        })
        |> Repo.insert!()

      inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      %FederationMembershipState{}
      |> FederationMembershipState.changeset(%{
        conversation_id: channel.id,
        remote_actor_id: remote_actor.id,
        origin_domain: "remote.example",
        role: "member",
        state: "invited",
        updated_at_remote: inserted_at,
        metadata: %{"join_request" => true, "reason" => "approval_required"}
      })
      |> Repo.insert!()

      assert {:ok, declined_request} =
               Messaging.decline_remote_join_request(channel.id, remote_actor.id, owner.id)

      assert declined_request.state == "left"

      assert %FederationMembershipState{} =
               membership_state =
               Repo.get_by(FederationMembershipState,
                 conversation_id: channel.id,
                 remote_actor_id: remote_actor.id
               )

      assert membership_state.state == "left"
      assert get_in(membership_state.metadata, ["join_request"]) == false
      assert get_in(membership_state.metadata, ["join_decision"]) == "declined"
      assert Messaging.list_pending_remote_join_requests(channel.id) == []
    end
  end
end
