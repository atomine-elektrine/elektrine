defmodule Elektrine.Messaging.ChatConversationsCreditsTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures

  alias Atomine.Credits
  alias Elektrine.Accounts.User
  alias Elektrine.Messaging
  alias Elektrine.Repo

  setup do
    previous_config = Application.get_env(:atomine, :credits, [])
    Application.put_env(:atomine, :credits, dm_gate_enabled: true)

    on_exit(fn ->
      Application.put_env(:atomine, :credits, previous_config)
    end)

    :ok
  end

  test "TL0 users spend an Atomine Credit to create a first DM" do
    alice = user_fixture()
    bob = user_fixture()

    assert {:error, :insufficient_dm_credits} = Messaging.create_dm_conversation(alice.id, bob.id)

    assert {:ok, _ledger_entry} = Credits.grant(alice.id, :atomine_credit, 1, "test_grant")

    assert {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
    assert conversation.type == "dm"
    assert Credits.balance(alice.id, :atomine_credit) == 0

    assert {:ok, existing_conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
    assert existing_conversation.id == conversation.id
    assert Credits.balance(alice.id, :atomine_credit) == 0
  end

  test "TL1 users can create first DMs without credits" do
    alice = promote_to_trust_level(user_fixture(), 1)
    bob = user_fixture()

    assert {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
    assert conversation.type == "dm"
    assert Credits.balance(alice.id, :atomine_credit) == 0
  end

  defp promote_to_trust_level(%User{} = user, trust_level) do
    user
    |> User.trust_level_changeset(%{trust_level: trust_level})
    |> Repo.update!()
  end
end
