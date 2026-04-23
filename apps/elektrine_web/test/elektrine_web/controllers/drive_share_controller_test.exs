defmodule ElektrineWeb.DriveShareControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.{Accounts, Drive, Repo}

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(System.tmp_dir!(), "elektrine-drive-share-#{System.unique_integer([:positive])}")

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
    {:ok, file} = Drive.upload_file(user, "shared", temp_upload("hello.txt", "share me"))
    {:ok, share} = Drive.create_share(user.id, file.id)

    {:ok, user: user, stored_file: file, share: share}
  end

  test "downloads a shared file", %{conn: conn, share: share} do
    conn = get(conn, ~p"/drive/share/#{share.token}")

    assert response(conn, 200) == "share me"

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"hello.txt\""
           ]

    assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]

    assert Repo.get!(Drive.FileShare, share.id).download_count == 1
  end

  test "requires password for protected share links", %{conn: conn, user: user, stored_file: file} do
    {:ok, protected_share} = Drive.create_share(user.id, file.id, %{password: "secret-pass"})

    conn = get(conn, ~p"/drive/share/#{protected_share.token}")
    assert response(conn, 200) =~ "Password Protected Link"

    conn = post(conn, ~p"/drive/share/#{protected_share.token}", %{"password" => "secret-pass"})
    assert redirected_to(conn) == ~p"/drive/share/#{protected_share.token}"

    conn =
      build_conn()
      |> init_test_session(%{"drive_share_access" => [protected_share.token]})
      |> get(~p"/drive/share/#{protected_share.token}")

    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "share password throttling resists ipv6 rotation within a /64", %{
    conn: conn,
    user: user,
    stored_file: file
  } do
    {:ok, protected_share} = Drive.create_share(user.id, file.id, %{password: "secret-pass"})

    attempts = [1, 2, 3, 4, 5]

    Enum.each(attempts, fn host_part ->
      conn =
        conn
        |> recycle()
        |> Map.put(:remote_ip, {0x2001, 0x0DB8, 0x1234, 0x5678, 0, 0, 0, host_part})
        |> post(~p"/drive/share/#{protected_share.token}", %{"password" => "wrong-pass"})

      assert response(conn, 401) =~ "Password was incorrect"
    end)

    conn =
      conn
      |> recycle()
      |> Map.put(:remote_ip, {0x2001, 0x0DB8, 0x1234, 0x5678, 0, 0, 0, 99})
      |> post(~p"/drive/share/#{protected_share.token}", %{"password" => "wrong-pass"})

    assert response(conn, 429) =~ "Too many attempts"
  end

  test "renders inline for view-mode shares", %{conn: conn, user: user} do
    {:ok, inline_file} =
      Drive.upload_file(user, "shared", temp_upload("hello-view.txt", "view me"))

    {:ok, view_share} = Drive.create_share(user.id, inline_file.id, %{access_level: "view"})

    conn = get(conn, ~p"/drive/share/#{view_share.token}")

    assert response(conn, 200) == "view me"
    assert get_resp_header(conn, "content-disposition") == []
  end

  test "forces html shares to download even in view mode", %{conn: conn, user: user} do
    upload = temp_upload("hello.html", "<script>alert(1)</script>")
    upload = %{upload | content_type: "text/html"}

    {:ok, html_file} = Drive.upload_file(user, "shared", upload)
    {:ok, view_share} = Drive.create_share(user.id, html_file.id, %{access_level: "view"})

    conn = get(conn, ~p"/drive/share/#{view_share.token}")

    assert response(conn, 200) == "<script>alert(1)</script>"

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"hello.html\""
           ]
  end

  test "returns 404 for revoked share links", %{conn: conn, user: user, share: share} do
    assert {:ok, _} = Drive.revoke_share(user.id, share.id)

    conn = get(conn, ~p"/drive/share/#{share.token}")
    assert response(conn, 404) == "Not found"
  end

  test "returns 404 for expired share links", %{conn: conn, share: share} do
    share
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    conn = get(conn, ~p"/drive/share/#{share.token}")
    assert response(conn, 404) == "Not found"
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        username: "shares#{System.unique_integer([:positive])}",
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
