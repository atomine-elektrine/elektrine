defmodule Elektrine.Accounts.AccountNotesTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo

  test "creates and updates private notes for local accounts" do
    source = user_fixture()
    target = user_fixture()

    assert {:ok, note} = Accounts.put_account_note(source.id, {:user, target.id}, " first ")
    assert note.comment == "first"
    assert Accounts.account_note_comment(source.id, {:user, target.id}) == "first"

    assert {:ok, updated} = Accounts.put_account_note(source.id, {:user, target.id}, "second")
    assert updated.id == note.id
    assert updated.comment == "second"
  end

  test "creates private notes for remote actors" do
    source = user_fixture()
    actor = remote_actor_fixture()

    assert {:ok, note} =
             Accounts.put_account_note(source.id, {:remote_actor, actor.id}, "remote note")

    assert note.comment == "remote note"
    assert Accounts.account_note_comment(source.id, {:remote_actor, actor.id}) == "remote note"
  end

  defp remote_actor_fixture do
    unique = System.unique_integer([:positive])

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.example/users/note#{unique}",
      username: "note#{unique}",
      domain: "remote.example",
      inbox_url: "https://remote.example/users/note#{unique}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n"
    })
    |> Repo.insert!()
  end
end
