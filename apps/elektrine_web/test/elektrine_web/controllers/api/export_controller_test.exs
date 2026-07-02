defmodule ElektrineWeb.API.ExportControllerTest do
  use ElektrineWeb.ConnCase, async: false
  use Oban.Testing, repo: Elektrine.Repo

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer
  alias Elektrine.Repo
  alias ElektrineWeb.API.ExportController

  describe "create/2" do
    test "defaults full exports to zip when format is omitted", %{conn: conn} do
      user = user_fixture()

      Oban.Testing.with_testing_mode(:manual, fn ->
        conn =
          conn
          |> assign(:current_user, user)
          |> ExportController.create(%{"type" => "full"})

        assert %{
                 "data" => %{
                   "message" => "Export queued successfully",
                   "export" => %{
                     "id" => export_id,
                     "type" => "full",
                     "format" => "zip",
                     "status" => "pending"
                   }
                 }
               } = json_response(conn, 202)

        assert_enqueued(
          worker: Elektrine.Developer.ExportWorker,
          args: %{"export_id" => export_id}
        )
      end)
    end

    test "rejects explicit invalid full export formats", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> ExportController.create(%{"type" => "full", "format" => "json"})

      assert %{
               "error" => %{
                 "code" => "invalid_export",
                 "details" => %{"format" => ["is not valid for full exports"]}
               }
             } = json_response(conn, 422)
    end
  end

  describe "show/2" do
    test "does not expose download URLs for pending exports", %{conn: conn} do
      user = user_fixture()

      {:ok, export} =
        Developer.create_export(user.id, %{
          export_type: "account",
          format: "json"
        })

      conn =
        conn
        |> assign(:current_user, user)
        |> ExportController.show(%{"id" => to_string(export.id)})

      assert %{
               "data" => %{
                 "export" => %{
                   "download_url" => nil,
                   "authenticated_download_url" => nil
                 }
               }
             } = json_response(conn, 200)
    end

    test "does not expose download URLs for expired completed exports", %{conn: conn} do
      user = user_fixture()

      {:ok, export} =
        Developer.create_export(user.id, %{
          export_type: "account",
          format: "json"
        })

      {:ok, export} = Developer.complete_export(export, "/tmp/expired-export.json", 12, 1)

      expired_at =
        DateTime.utc_now()
        |> DateTime.add(-60, :second)
        |> DateTime.truncate(:second)

      export
      |> Ecto.Changeset.change(expires_at: expired_at)
      |> Repo.update!()

      conn =
        conn
        |> assign(:current_user, user)
        |> ExportController.show(%{"id" => to_string(export.id)})

      assert %{
               "data" => %{
                 "export" => %{
                   "status" => "completed",
                   "download_url" => nil,
                   "authenticated_download_url" => nil
                 }
               }
             } = json_response(conn, 200)
    end

    test "exposes download URLs for downloadable completed exports", %{conn: conn} do
      user = user_fixture()

      {:ok, export} =
        Developer.create_export(user.id, %{
          export_type: "account",
          format: "json"
        })

      {:ok, export} = Developer.complete_export(export, "/tmp/ready-export.json", 12, 1)

      conn =
        conn
        |> assign(:current_user, user)
        |> ExportController.show(%{"id" => to_string(export.id)})

      assert %{
               "data" => %{
                 "export" => %{
                   "download_url" => download_url,
                   "authenticated_download_url" => authenticated_download_url
                 }
               }
             } = json_response(conn, 200)

      assert download_url == "/api/ext/v1/exports/#{export.id}/download"
      assert authenticated_download_url == download_url
    end
  end
end
