defmodule ElektrineWeb.KairoLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures

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

  defp mount_kairo(conn) do
    user = AccountsFixtures.user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/kairo")
    {user, view}
  end

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/kairo")
    assert String.starts_with?(to, "/login")
  end

  test "creates a note and finds it by content search", %{conn: conn} do
    {user, view} = mount_kairo(conn)

    render_click(view, "new_note")

    render_submit(view, "save_note", %{
      "note" => %{
        "title" => "Alpha",
        "content" => "unmistakable-needle body",
        "tags" => "one",
        "project_id" => ""
      }
    })

    assert [source] = Kairo.list_sources(user)
    assert source.title == "Alpha"

    html = render_change(view, "search", %{"query" => "unmistakable-needle"})
    assert html =~ "Alpha"

    html = render_change(view, "search", %{"query" => "no-such-content"})
    assert html =~ "No matching sources"
  end

  test "saves a link as a url source", %{conn: conn} do
    {user, view} = mount_kairo(conn)

    render_click(view, "toggle_add_link")

    render_submit(view, "save_link", %{
      "link" => %{
        "url" => "https://example.com/article",
        "title" => "",
        "tags" => "reading",
        "project_id" => ""
      }
    })

    assert [source] = Kairo.list_sources(user)
    assert source.source_type == "url"
    assert source.url == "https://example.com/article"
    assert source.status == "received"
  end

  test "uploads a file source from the explorer", %{conn: conn} do
    {user, view} = mount_kairo(conn)

    upload =
      file_input(view, "#kairo-upload-form", :kairo_files, [
        %{
          last_modified: 1_594_171_879_000,
          name: "notes.txt",
          content: "remember this file",
          type: "text/plain"
        }
      ])

    assert render_upload(upload, "notes.txt") =~ "notes.txt"

    view
    |> element("#kairo-upload-form")
    |> render_submit(%{"upload" => %{"project_id" => "", "tags" => "files"}})

    assert [source] = Kairo.list_sources(user)
    assert source.source_type == "file"
    assert source.content == "remember this file"
    assert source.tags == ["files"]
    assert source.metadata["key"] =~ "kairo-sources/#{user.id}/"
  end

  test "manages the project lifecycle", %{conn: conn} do
    {user, view} = mount_kairo(conn)

    render_submit(view, "create_project", %{"project" => %{"name" => "Research"}})
    assert [project] = Kairo.list_projects(user)

    render_submit(view, "rename_project", %{
      "project" => %{"id" => to_string(project.id), "name" => "Renamed"}
    })

    assert Kairo.get_project(user, project.id).name == "Renamed"

    render_click(view, "toggle_archive_project", %{"id" => to_string(project.id)})
    assert Kairo.get_project(user, project.id).status == "archived"

    render_click(view, "delete_project", %{"id" => to_string(project.id)})
    assert Kairo.list_projects(user) == []
  end

  test "saves an encrypted note pushed from the vault hook", %{conn: conn} do
    {user, view} = mount_kairo(conn)

    payload = %{
      "version" => 2,
      "algorithm" => "AES-GCM",
      "iv" => Base.encode64(:crypto.strong_rand_bytes(12)),
      "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48))
    }

    render_hook(view, "save_encrypted_note", %{
      "note" => %{"title" => "Secret", "tags" => "", "project_id" => ""},
      "payload" => payload
    })

    assert [source] = Kairo.list_sources(user)
    assert source.encrypted
    assert source.content == nil
    assert source.encrypted_content["ciphertext"] == payload["ciphertext"]
  end

  test "refuses a plaintext submit flagged for encryption", %{conn: conn} do
    {user, view} = mount_kairo(conn)

    render_click(view, "new_note")

    render_submit(view, "save_note", %{
      "note" => %{"title" => "Leak", "content" => "secret", "encrypt" => "true"}
    })

    assert Kairo.list_sources(user) == []
  end
end
