defmodule ElektrineWeb.FilesLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{Accounts, Files}

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(System.tmp_dir!(), "elektrine-files-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.put_env(:elektrine, :uploads,
      adapter: :local,
      uploads_dir: tmp_dir
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :uploads, previous_uploads)
      File.rm_rf(tmp_dir)
    end)

    user = user_fixture()
    {:ok, _} = Files.upload_file(user, "projects/alpha", temp_upload("roadmap.txt", "v1"))
    {:ok, _} = Files.upload_file(user, "projects/beta", temp_upload("launch.txt", "v2"))
    {:ok, _} = Files.upload_file(user, "", temp_upload("root.txt", "root"))
    {:ok, _} = Files.upload_file(user, "", temp_upload("photo.png", "pngdata"))

    {:ok, user: user}
  end

  test "shows folders and navigates into them", %{conn: conn, user: user} do
    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/files")

    assert has_element?(view, "a", "projects")
    assert has_element?(view, "p", "root.txt")

    view
    |> element(~s(a[href="/account/files?folder=projects"]), "projects")
    |> render_click()

    assert has_element?(view, "a", "alpha")
    assert has_element?(view, "a", "beta")
    refute render(view) =~ "root.txt"
  end

  test "expands the folder tree", %{conn: conn, user: user} do
    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/files")

    refute render(view) =~ "projects/alpha"

    view
    |> element("button[phx-click='toggle_tree_node'][phx-value-path='projects']")
    |> render_click()

    assert render(view) =~ "alpha"
    assert render(view) =~ "beta"
  end

  test "filters files by search query", %{conn: conn, user: user} do
    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/files")

    render_change(view, "filter", %{"filters" => %{"q" => "root", "sort" => "updated_desc"}})

    assert render(view) =~ "root.txt"
    refute has_element?(view, "article a", "projects")
  end

  test "uses quick filters for low-typing exploration", %{conn: conn, user: user} do
    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/files")

    view
    |> element(~s(a[href="/account/files?filter=images"]), "Images")
    |> render_click()

    assert render(view) =~ "photo.png"
    refute render(view) =~ "root.txt"
  end

  test "shows the upload queue after selecting a file", %{conn: conn, user: user} do
    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/files")

    upload =
      file_input(view, "#file-explorer-upload-picker", :files, [
        %{
          last_modified: 1_594_171_879_000,
          name: "queued.txt",
          content: "queued content",
          type: "text/plain"
        }
      ])

    html = render_upload(upload, "queued.txt")

    assert html =~ "Upload Queue"
    assert html =~ "queued.txt"
    assert has_element?(view, "button", "Finish upload")
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        username: "fileslive#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    user
  end

  defp temp_upload(filename, content) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, content)

    %Plug.Upload{
      path: path,
      filename: filename,
      content_type: MIME.from_path(filename) || "application/octet-stream"
    }
  end
end
