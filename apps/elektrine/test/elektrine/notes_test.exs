defmodule Elektrine.NotesTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.{AccountsFixtures, Notes}

  test "list_notes returns pinned notes first and filters by query" do
    user = AccountsFixtures.user_fixture()

    {:ok, older_note} = Notes.create_note(user.id, %{title: "Alpha", body: "first body"})
    {:ok, _updated_note} = Notes.toggle_note_pin(older_note)
    {:ok, _newer_note} = Notes.create_note(user.id, %{title: "Bravo", body: "target body"})

    notes = Notes.list_notes(user.id)

    assert Enum.map(notes, & &1.title) == ["Alpha", "Bravo"]
    assert Enum.map(Notes.list_notes(user.id, q: "target"), & &1.title) == ["Bravo"]
  end

  test "create_note requires either a title or body" do
    user = AccountsFixtures.user_fixture()

    assert {:error, changeset} = Notes.create_note(user.id, %{title: "   ", body: "   "})
    assert "can't be blank" in errors_on(changeset).body
  end

  test "creates and revokes a public note share" do
    user = AccountsFixtures.user_fixture()
    {:ok, note} = Notes.create_note(user.id, %{title: "Paste", body: "hello world"})

    assert {:ok, share} = Notes.create_note_share(user.id, note)
    assert share.note_id == note.id
    assert is_binary(share.token)
    assert Notes.get_active_share_for_note(user.id, note.id).id == share.id
    assert Notes.get_public_share(share.token).id == share.id

    assert {:ok, %{revoked_count: 1}} = Notes.revoke_note_share(user.id, note)
    assert is_nil(Notes.get_active_share_for_note(user.id, note.id))
    assert is_nil(Notes.get_public_share(share.token))
  end

  test "get_active_share_for_note returns the latest active share when multiples exist" do
    user = AccountsFixtures.user_fixture()
    {:ok, note} = Notes.create_note(user.id, %{title: "Paste", body: "hello world"})

    assert {:ok, first} =
             Notes.create_encrypted_note_share(user.id, note, %{
               "version" => 1,
               "algorithm" => "xchacha20-poly1305",
               "iv" => "one",
               "ciphertext" => "one"
             })

    assert {:ok, second} =
             Notes.create_encrypted_note_share(user.id, note, %{
               "version" => 1,
               "algorithm" => "xchacha20-poly1305",
               "iv" => "two",
               "ciphertext" => "two"
             })

    assert first.id != second.id
    assert Notes.get_active_share_for_note(user.id, note.id).id == second.id
  end
end
