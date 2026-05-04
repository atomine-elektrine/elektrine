defmodule Elektrine.Messaging.ChatConversationsTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts.User
  alias Elektrine.Messaging
  alias Elektrine.Repo

  test "created chat conversations use hashes for chat paths" do
    alice = promote_to_trust_level(user_fixture(), 1)
    bob = user_fixture()

    assert {:ok, dm} = Messaging.create_dm_conversation(alice.id, bob.id)
    assert dm.hash =~ ~r/^[0-9a-f]{32}$/
    assert Elektrine.Paths.chat_path(dm) == "/chat/#{dm.hash}"

    assert {:ok, group} =
             Messaging.create_chat_group_conversation(alice.id, %{name: "Hash Group"}, [bob.id])

    assert group.hash =~ ~r/^[0-9a-f]{32}$/
    assert Elektrine.Paths.chat_path(group) == "/chat/#{group.hash}"
  end

  defp promote_to_trust_level(%User{} = user, trust_level) do
    user
    |> User.trust_level_changeset(%{trust_level: trust_level})
    |> Repo.update!()
  end
end
