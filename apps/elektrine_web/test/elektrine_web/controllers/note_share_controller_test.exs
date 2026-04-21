defmodule ElektrineWeb.NoteShareControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.{AccountsFixtures, Notes, Repo}

  test "renders a shared note", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, note} = Notes.create_note(user.id, %{title: "Paste", body: "hello\nworld"})
    {:ok, share} = Notes.create_note_share(user.id, note)

    conn = get(conn, ~p"/notes/share/#{share.token}")

    assert html_response(conn, 200) =~ "Paste"
    assert html_response(conn, 200) =~ "hello\nworld"
    assert Repo.get!(Notes.NoteShare, share.id).view_count == 1
  end

  test "returns 404 for revoked note shares", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, note} = Notes.create_note(user.id, %{title: "Paste", body: "hello"})
    {:ok, share} = Notes.create_note_share(user.id, note)
    {:ok, _revoked_share} = Notes.revoke_note_share(user.id, note)

    conn = get(conn, ~p"/notes/share/#{share.token}")

    assert response(conn, 404) == "Not found"
  end
end
