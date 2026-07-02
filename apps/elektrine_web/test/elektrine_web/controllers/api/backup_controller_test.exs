defmodule ElektrineWeb.API.BackupControllerTest do
  use ElektrineWeb.ConnCase, async: false
  use Oban.Testing, repo: Elektrine.Repo

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer
  alias ElektrineWeb.API.BackupController

  describe "index/2" do
    test "lists only account backup exports for the current user", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()

      {:ok, account_export} =
        Developer.create_export(user.id, %{export_type: "account", format: "json"})

      {:ok, full_export} =
        Developer.create_export(user.id, %{export_type: "full", format: "zip"})

      {:ok, _social_export} =
        Developer.create_export(user.id, %{export_type: "social", format: "json"})

      {:ok, _other_export} =
        Developer.create_export(other_user.id, %{export_type: "account", format: "json"})

      conn =
        conn
        |> assign(:current_user, user)
        |> BackupController.index(%{})

      ids =
        conn
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert to_string(account_export.id) in ids
      assert to_string(full_export.id) in ids
      assert length(ids) == 2
    end
  end

  describe "create/2" do
    test "queues account backups with explicit metadata", %{conn: conn} do
      user = user_fixture()

      Oban.Testing.with_testing_mode(:manual, fn ->
        conn =
          conn
          |> assign(:current_user, user)
          |> BackupController.create(%{"type" => "account", "format" => "json"})

        assert %{
                 "id" => id,
                 "type" => "account",
                 "status" => "pending",
                 "processed" => false,
                 "authenticated_download_url" => nil
               } = json_response(conn, 202)

        assert_enqueued(
          worker: Elektrine.Developer.ExportWorker,
          args: %{"export_id" => String.to_integer(id)}
        )
      end)
    end

    test "rejects non-backup export types", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> BackupController.create(%{"type" => "social", "format" => "json"})

      assert %{"error" => "type must be account or full"} = json_response(conn, 400)
    end

    test "rejects invalid backup formats before enqueueing", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> BackupController.create(%{"type" => "full", "format" => "json"})

      assert %{"error" => "format is not valid for this backup type"} = json_response(conn, 400)
    end

    test "rejects account CSV backups because account exports are JSON", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> BackupController.create(%{"type" => "account", "format" => "csv"})

      assert %{"error" => "format is not valid for this backup type"} = json_response(conn, 400)
    end
  end

  describe "show/2" do
    test "returns one backup with completed download metadata", %{conn: conn} do
      user = user_fixture()

      {:ok, export} =
        Developer.create_export(user.id, %{export_type: "account", format: "json"})

      {:ok, export} = Developer.complete_export(export, "/tmp/backup-export.json", 128, 4)

      conn =
        conn
        |> assign(:current_user, user)
        |> BackupController.show(%{"id" => to_string(export.id)})

      assert %{
               "id" => id,
               "type" => "account",
               "processed" => true,
               "status" => "completed",
               "file_size" => 128,
               "url" => download_url,
               "download_url" => download_url,
               "authenticated_download_url" => authenticated_download_url
             } = json_response(conn, 200)

      assert id == to_string(export.id)
      assert download_url == "/api/ext/v1/exports/#{export.id}/download"
      assert authenticated_download_url == download_url
    end

    test "does not expose non-backup exports", %{conn: conn} do
      user = user_fixture()

      {:ok, export} =
        Developer.create_export(user.id, %{export_type: "social", format: "json"})

      conn =
        conn
        |> assign(:current_user, user)
        |> BackupController.show(%{"id" => to_string(export.id)})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "does not expose backups owned by another user", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()

      {:ok, export} =
        Developer.create_export(other_user.id, %{export_type: "account", format: "json"})

      conn =
        conn
        |> assign(:current_user, user)
        |> BackupController.show(%{"id" => to_string(export.id)})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end

  describe "delete/2" do
    test "deletes only backups owned by the current user", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()

      {:ok, export} =
        Developer.create_export(user.id, %{export_type: "account", format: "json"})

      {:ok, other_export} =
        Developer.create_export(other_user.id, %{export_type: "account", format: "json"})

      delete_conn =
        conn
        |> assign(:current_user, user)
        |> BackupController.delete(%{"id" => to_string(export.id)})

      assert %{"id" => id, "deleted" => true} = json_response(delete_conn, 200)
      assert id == to_string(export.id)

      missing_conn =
        build_conn()
        |> assign(:current_user, user)
        |> BackupController.delete(%{"id" => to_string(other_export.id)})

      assert %{"error" => "not found"} = json_response(missing_conn, 404)
    end

    test "does not delete non-backup exports", %{conn: conn} do
      user = user_fixture()

      {:ok, export} =
        Developer.create_export(user.id, %{export_type: "social", format: "json"})

      conn =
        conn
        |> assign(:current_user, user)
        |> BackupController.delete(%{"id" => to_string(export.id)})

      assert %{"error" => "not found"} = json_response(conn, 404)
      assert Developer.get_export(user.id, export.id)
    end
  end
end
