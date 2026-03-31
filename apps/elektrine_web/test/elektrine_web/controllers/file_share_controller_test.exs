defmodule ElektrineWeb.FileShareControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.{Accounts, Files, Repo}

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(System.tmp_dir!(), "elektrine-file-share-#{System.unique_integer([:positive])}")

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
    {:ok, file} = Files.upload_file(user, "shared", temp_upload("hello.txt", "share me"))
    {:ok, share} = Files.create_share(user.id, file.id)

    {:ok, user: user, stored_file: file, share: share}
  end

  test "downloads a shared file", %{conn: conn, share: share} do
    conn = get(conn, ~p"/files/share/#{share.token}")

    assert response(conn, 200) == "share me"

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"hello.txt\""
           ]

    assert Repo.get!(Files.FileShare, share.id).download_count == 1
  end

  test "requires password for protected share links", %{conn: conn, user: user, stored_file: file} do
    {:ok, protected_share} = Files.create_share(user.id, file.id, %{password: "secret-pass"})

    conn = get(conn, ~p"/files/share/#{protected_share.token}")
    assert response(conn, 200) =~ "Password Protected Link"

    conn = post(conn, ~p"/files/share/#{protected_share.token}", %{"password" => "secret-pass"})
    assert redirected_to(conn) == ~p"/files/share/#{protected_share.token}"
  end

  test "renders inline for view-mode shares", %{conn: conn, user: user} do
    {:ok, inline_file} =
      Files.upload_file(user, "shared", temp_upload("hello-view.txt", "view me"))

    {:ok, view_share} = Files.create_share(user.id, inline_file.id, %{access_level: "view"})

    conn = get(conn, ~p"/files/share/#{view_share.token}")

    assert response(conn, 200) == "view me"
    assert get_resp_header(conn, "content-disposition") == []
  end

  test "returns 404 for revoked share links", %{conn: conn, user: user, share: share} do
    assert {:ok, _} = Files.revoke_share(user.id, share.id)

    conn = get(conn, ~p"/files/share/#{share.token}")
    assert response(conn, 404) == "Not found"
  end

  test "returns 404 for expired share links", %{conn: conn, share: share} do
    share
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    conn = get(conn, ~p"/files/share/#{share.token}")
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
