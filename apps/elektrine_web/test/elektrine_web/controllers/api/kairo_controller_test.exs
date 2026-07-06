defmodule ElektrineWeb.API.KairoControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer
  alias ElektrineWeb.API.KairoController

  defp as_user(conn, user), do: assign(conn, :current_user, user)

  defp token_for(user, scopes) do
    {:ok, token} =
      Developer.create_api_token(user.id, %{
        name: "Kairo API test token",
        scopes: scopes
      })

    token.token
  end

  describe "projects" do
    test "create, update, and delete a project", %{conn: conn} do
      user = user_fixture()

      conn = conn |> as_user(user) |> KairoController.create_project(%{"name" => "Research"})

      assert %{"data" => %{"project" => %{"id" => id, "slug" => "research"}}} =
               json_response(conn, 201)

      conn =
        build_conn()
        |> as_user(user)
        |> KairoController.update_project(%{"id" => id, "status" => "archived"})

      assert %{"data" => %{"project" => %{"status" => "archived"}}} = json_response(conn, 200)

      conn =
        build_conn()
        |> as_user(user)
        |> KairoController.delete_project(%{"id" => id})

      assert %{"data" => %{"deleted" => true}} = json_response(conn, 200)
      assert Kairo.get_project(user, id) == nil
    end
  end

  describe "sources" do
    test "create, update, and delete a source", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> as_user(user)
        |> KairoController.create_source(%{
          "source_type" => "markdown",
          "title" => "Note",
          "content" => "hello kairo"
        })

      assert %{"data" => %{"source" => %{"id" => id, "content" => "hello kairo"}}} =
               json_response(conn, 201)

      conn =
        build_conn()
        |> as_user(user)
        |> KairoController.update_source(%{"id" => id, "title" => "Renamed"})

      assert %{"data" => %{"source" => %{"title" => "Renamed"}}} = json_response(conn, 200)

      conn =
        build_conn()
        |> as_user(user)
        |> KairoController.delete_source(%{"id" => id})

      assert %{"data" => %{"deleted" => true}} = json_response(conn, 200)
      assert Kairo.get_source(user, id) == nil
    end

    test "duplicate ingest returns the existing source", %{conn: conn} do
      user = user_fixture()
      attrs = %{"source_type" => "markdown", "title" => "Dup", "content" => "same"}

      conn = conn |> as_user(user) |> KairoController.create_source(attrs)
      assert %{"data" => %{"source" => %{"id" => id}}} = json_response(conn, 201)

      conn = build_conn() |> as_user(user) |> KairoController.create_source(attrs)
      assert %{"data" => %{"source" => %{"id" => ^id}}} = json_response(conn, 201)
    end

    test "create source accepts a file upload", %{conn: conn} do
      user = user_fixture()
      upload = temp_upload("api-notes.txt", "api upload body", "text/plain")

      conn =
        conn
        |> as_user(user)
        |> KairoController.create_source(%{"file" => upload, "tags" => "api"})

      assert %{
               "data" => %{
                 "source" => %{
                   "source_type" => "file",
                   "content" => "api upload body",
                   "tags" => ["api"],
                   "metadata" => %{"key" => key}
                 }
               }
             } = json_response(conn, 201)

      assert key =~ "kairo-sources/#{user.id}/"
    end

    test "extension route accepts multipart file uploads", %{conn: conn} do
      user = user_fixture()
      token = token_for(user, ["write:kairo"])
      upload = temp_upload("linked-file.txt", "linked body", "text/plain")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/ext/v1/kairo/sources", %{
          "source" => %{
            "file" => upload,
            "title" => "linked-file.txt",
            "url" => "https://example.com/linked-file.txt",
            "tags" => "capture, browser-extension",
            "metadata" => %{"capture_type" => "file"}
          }
        })

      assert %{
               "data" => %{
                 "source" => %{
                   "source_type" => "file",
                   "title" => "linked-file.txt",
                   "url" => "https://example.com/linked-file.txt",
                   "content" => "linked body",
                   "metadata" => %{"capture_type" => "file", "key" => key}
                 }
               }
             } = json_response(conn, 201)

      assert key =~ "kairo-sources/#{user.id}/"
    end

    test "sources listing supports offset pagination", %{conn: conn} do
      user = user_fixture()

      for index <- 1..3 do
        {:ok, _} =
          Kairo.create_source(user, %{
            "source_type" => "markdown",
            "title" => "Note #{index}",
            "content" => "body #{index}"
          })
      end

      conn = conn |> as_user(user) |> KairoController.sources(%{"limit" => "2", "offset" => "2"})
      assert %{"data" => %{"sources" => [_only_one]}} = json_response(conn, 200)
    end

    test "update and delete enforce ownership", %{conn: conn} do
      owner = user_fixture()
      intruder = user_fixture()

      {:ok, source} =
        Kairo.create_source(owner, %{
          "source_type" => "markdown",
          "title" => "Private",
          "content" => "owner only"
        })

      # Direct action calls bypass action_fallback, so not-found surfaces as
      # the fallback tuple rather than a rendered 404.
      assert {:error, :not_found} =
               conn
               |> as_user(intruder)
               |> KairoController.update_source(%{"id" => source.id, "title" => "stolen"})

      assert {:error, :not_found} =
               build_conn()
               |> as_user(intruder)
               |> KairoController.delete_source(%{"id" => source.id})

      assert Kairo.get_source(owner, source.id).title == "Private"
    end
  end

  defp temp_upload(filename, content, content_type) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kairo-api-upload-test-#{System.unique_integer([:positive])}-#{filename}"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end
end
