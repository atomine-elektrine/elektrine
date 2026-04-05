defmodule ElektrineWeb.FilesControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.{Accounts, Files}

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "elektrine-files-controller-#{System.unique_integer([:positive])}"
      )

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
    {:ok, file} = Files.upload_file(user, "private", temp_upload("secret.txt", "top secret"))

    {:ok, user: user, stored_file: file}
  end

  test "downloads an owned file", %{conn: conn, user: user, stored_file: file} do
    conn = get(log_in_user(conn, user), ~p"/account/files/#{file.id}/download")

    assert response(conn, 200) == "top secret"

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"secret.txt\""
           ]
  end

  test "previews inline-viewable files", %{conn: conn, user: user, stored_file: file} do
    conn = get(log_in_user(conn, user), ~p"/account/files/#{file.id}/preview")

    assert response(conn, 200) == "top secret"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "prevents downloading another user's file", %{conn: conn, stored_file: file} do
    other_user = user_fixture()
    conn = get(log_in_user(conn, other_user), ~p"/account/files/#{file.id}/download")

    assert response(conn, 404) == "Not found"
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

  defp user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        username: "downloads#{System.unique_integer([:positive])}",
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
