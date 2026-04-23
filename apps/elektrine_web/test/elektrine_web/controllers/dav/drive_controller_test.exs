defmodule ElektrineWeb.DAV.DriveControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.Accounts

  @test_password "testpassword123"

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(System.tmp_dir!(), "elektrine-dav-drive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.put_env(:elektrine, :uploads,
      adapter: :local,
      uploads_dir: tmp_dir
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :uploads, previous_uploads)
      File.rm_rf(tmp_dir)
    end)

    {:ok, user: user_fixture()}
  end

  test "PROPFIND lists the DAV home", %{conn: conn, user: user} do
    conn =
      conn
      |> auth_conn(user)
      |> put_req_header("depth", "1")
      |> request(:propfind, "/drive-dav/#{user.username}")

    assert conn.status == 207
    assert conn.resp_body =~ "/drive-dav/#{user.username}/"
  end

  test "PUT, GET, MKCOL, MOVE and DELETE work for DAV drive items", %{conn: conn, user: user} do
    conn =
      conn
      |> auth_conn(user)
      |> request(:mkcol, "/drive-dav/#{user.username}/docs")

    assert conn.status == 201

    conn =
      build_conn()
      |> auth_conn(user)
      |> put_req_header("content-type", "text/plain")
      |> request(:put, "/drive-dav/#{user.username}/docs/note.txt", "hello dav")

    assert conn.status == 201

    conn = build_conn() |> auth_conn(user) |> get("/drive-dav/#{user.username}/docs/note.txt")
    assert response(conn, 200) == "hello dav"

    conn =
      build_conn()
      |> auth_conn(user)
      |> put_req_header(
        "destination",
        "http://localhost:4002/drive-dav/#{user.username}/docs/moved.txt"
      )
      |> request(:move, "/drive-dav/#{user.username}/docs/note.txt")

    assert conn.status == 201

    conn = build_conn() |> auth_conn(user) |> delete("/drive-dav/#{user.username}/docs/moved.txt")
    assert conn.status == 204
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        username: "davdrive#{System.unique_integer([:positive])}",
        password: @test_password,
        password_confirmation: @test_password
      })

    user
  end

  defp auth_conn(conn, user) do
    encoded = Base.encode64("#{user.username}:#{@test_password}")
    put_req_header(conn, "authorization", "Basic #{encoded}")
  end

  defp request(conn, method, path, body \\ nil) do
    conn =
      if method in [:propfind, :mkcol, :move] and get_req_header(conn, "content-type") == [] do
        put_req_header(conn, "content-type", "application/xml")
      else
        conn
      end

    Phoenix.ConnTest.dispatch(conn, ElektrineWeb.Endpoint, method, path, body || "")
  end
end
