defmodule ElektrineWeb.NotesLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{AccountsFixtures, Notes}

  test "shows notes and filters by query", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, _note} = Notes.create_note(user.id, %{title: "Roadmap", body: "launch prep"})
    {:ok, _note} = Notes.create_note(user.id, %{title: "Scratch", body: "throwaway"})

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/notes")

    assert render(view) =~ "Roadmap"
    assert render(view) =~ "Scratch"

    render_change(view, "filter", %{"filters" => %{"q" => "launch"}})

    assert_patch(view, ~p"/account/notes?q=launch")
    assert render(view) =~ "Roadmap"
    refute render(view) =~ "Scratch"
  end

  test "creates, pins, and deletes a note", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/notes")

    view
    |> form("form[phx-submit='save_note']", %{
      "note" => %{"title" => "Ops", "body" => "Run backups"}
    })
    |> render_submit()

    note = hd(Notes.list_notes(user.id))

    assert_patch(view, ~p"/account/notes?note=#{note.id}")
    assert render(view) =~ "Ops"

    view
    |> element("button[phx-click='toggle_pin'][phx-value-id='#{note.id}']")
    |> render_click()

    assert render(view) =~ "Pinned"

    view
    |> element("button[phx-click='delete_note'][phx-value-id='#{note.id}']")
    |> render_click()

    assert Notes.list_notes(user.id) == []
    refute render(view) =~ "Ops"
  end

  test "creates and revokes an encrypted note share link", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, note} = Notes.create_note(user.id, %{title: "Paste", body: "hello world"})

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/notes?note=#{note.id}")

    render_hook(view, "create_encrypted_share", %{
      "id" => to_string(note.id),
      "key" => "test-key",
      "payload" => %{
        "version" => 1,
        "algorithm" => "AES-GCM-256",
        "iv" => "test-iv",
        "ciphertext" => "test-ciphertext"
      },
      "expires_in" => "1h",
      "burn_after_read" => true
    })

    share = Notes.get_active_share_for_note(user.id, note.id)

    assert share.encrypted_payload["algorithm"] == "AES-GCM-256"
    assert share.burn_after_read
    assert DateTime.diff(share.expires_at, DateTime.utc_now(), :second) in 1..3600
    assert render(view) =~ "This note has an encrypted share"

    html =
      conn
      |> get(~p"/notes/share/#{share.token}")
      |> html_response(200)

    assert html =~ "Encrypted Shared Note"
    assert html =~ "Burn after read"
    assert html =~ "Expiration"
    assert html =~ "Raw view"
    assert html =~ "test-ciphertext"
    refute html =~ "hello world"

    conn
    |> get(~p"/notes/share/#{share.token}")
    |> response(404)

    view
    |> element("button[phx-click='revoke_share'][phx-value-id='#{note.id}']")
    |> render_click()

    refute render(view) =~ share.token
    assert is_nil(Notes.get_active_share_for_note(user.id, note.id))
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
