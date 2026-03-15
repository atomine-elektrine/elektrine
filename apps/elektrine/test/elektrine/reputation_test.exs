defmodule Elektrine.ReputationTest do
  use Elektrine.DataCase

  alias Elektrine.{Accounts, Profiles, Reputation}
  alias Elektrine.AccountsFixtures

  test "build_public_graph exposes trust, invite lineage, and visible network samples" do
    unique = System.unique_integer([:positive])

    inviter = AccountsFixtures.user_fixture(%{username: "inviter#{unique}"})
    subject = AccountsFixtures.user_fixture(%{username: "subject#{unique}"})
    invitee = AccountsFixtures.user_fixture(%{username: "invitee#{unique}"})

    hidden_invitee =
      AccountsFixtures.user_fixture(%{username: "hidden#{unique}", profile_visibility: "private"})

    follower = AccountsFixtures.user_fixture(%{username: "follower#{unique}"})
    followee = AccountsFixtures.user_fixture(%{username: "followee#{unique}"})

    {:ok, inviter_code} =
      Accounts.create_invite_code(%{
        code: "ROOTAA#{unique}",
        created_by_id: inviter.id
      })

    {:ok, _used_subject_code} = Accounts.use_invite_code(inviter_code.code, subject.id)

    {:ok, subject_code} =
      Accounts.create_invite_code(%{
        code: "BRANCH#{unique}",
        max_uses: 2,
        created_by_id: subject.id
      })

    {:ok, _used_invitee_code} = Accounts.use_invite_code(subject_code.code, invitee.id)
    {:ok, _used_hidden_code} = Accounts.use_invite_code(subject_code.code, hidden_invitee.id)
    {:ok, _follow} = Profiles.follow_user(follower.id, subject.id)
    {:ok, _follow} = Profiles.follow_user(subject.id, followee.id)
    {:ok, subject} = Accounts.admin_update_user(subject, %{trust_level: 2})

    graph = Reputation.build_public_graph(subject)

    assert graph.subject.handle == subject.handle
    assert Enum.any?(graph.nodes, &(&1.id == "trust:#{subject.id}" and &1.label == "TL2"))

    assert Enum.any?(
             graph.nodes,
             &(&1.id == "inviter:#{inviter.id}" and &1.label == "@#{inviter.handle}")
           )

    assert Enum.any?(
             graph.nodes,
             &(&1.id == "invitee:#{invitee.id}" and &1.label == "@#{invitee.handle}")
           )

    assert Enum.any?(
             graph.nodes,
             &(&1.id == "follower:#{follower.id}" and &1.label == "@#{follower.handle}")
           )

    assert Enum.any?(
             graph.nodes,
             &(&1.id == "following:#{followee.id}" and &1.label == "@#{followee.handle}")
           )

    refute Enum.any?(graph.nodes, &(&1.label == "@#{hidden_invitee.handle}"))
    assert Enum.find(graph.stats, &(&1.label == "Invitees")).value == "2"
  end

  test "search_public_users returns only public graph subjects" do
    unique = System.unique_integer([:positive])

    public_user = AccountsFixtures.user_fixture(%{username: "graphpublic#{unique}"})

    _private_user =
      AccountsFixtures.user_fixture(%{
        username: "graphprivate#{unique}",
        display_name: "Graph Private #{unique}",
        profile_visibility: "private"
      })

    results = Reputation.search_public_users("graph")

    assert Enum.any?(results, &(&1.username == public_user.username))
    refute Enum.any?(results, &(&1.username == "graphprivate#{unique}"))
  end
end
