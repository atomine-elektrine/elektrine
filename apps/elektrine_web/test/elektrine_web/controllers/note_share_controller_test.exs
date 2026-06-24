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

  test "escapes encrypted payload JSON inside script data blocks", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, note} = Notes.create_note(user.id, %{title: "Encrypted", body: "secret"})

    {:ok, share} =
      Notes.create_encrypted_note_share(user.id, note, %{
        "version" => "v1",
        "algorithm" => "aes-gcm",
        "iv" => "iv",
        "ciphertext" => "</script><script>alert(1)</script>"
      })

    conn = get(conn, ~p"/notes/share/#{share.token}")
    html = html_response(conn, 200)

    refute html =~ "</script><script>alert(1)</script>"
    assert html =~ "\\u003C/script\\u003E\\u003Cscript\\u003Ealert(1)\\u003C/script\\u003E"
  end
end
