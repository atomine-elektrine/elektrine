defmodule ElektrineWeb.API.RelationshipImportControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias ElektrineWeb.API.RelationshipImportController
  alias ElektrineWeb.Plugs.APIAuth

  describe "create/2" do
    test "rejects unknown import types instead of defaulting to follows", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{
          "type" => "favorites",
          "accounts" => ["alice@example.com"]
        })

      assert %{"error" => "type must be one of follows, mutes, blocks, or domain_blocks"} =
               json_response(conn, 400)
    end

    test "normalizes supported import types and parses account data", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{
          "type" => "mutes",
          "data" => "alice@example.com\nbob@example.com"
        })

      assert %{"type" => "mute", "queued" => 2} = json_response(conn, 200)
    end

    test "imports first-column account CSV exports without queuing headers or options", %{
      conn: conn
    } do
      user = user_fixture()

      csv = """
      Account address,Show boosts,Notify on new posts,Languages
      alice@example.com,true,false,
      "bob@example.com",false,true,en
      """

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{
          "type" => "blocks",
          "csv" => csv
        })

      assert %{"type" => "block", "queued" => 2} = json_response(conn, 200)
    end

    test "ignores UTF-8 BOMs in CSV headers and identifiers", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{
          "type" => "domain_blocks",
          "csv" => <<0xEF, 0xBB, 0xBF>> <> "Domain\nExample.COM\n"
        })

      assert %{"type" => "domain_block", "queued" => 1} = json_response(conn, 200)
      assert Accounts.list_blocked_domains(user.id) == ["example.com"]
    end

    test "imports account CSV uploads", %{conn: conn} do
      user = user_fixture()

      upload =
        upload_fixture("""
        Account address,Show boosts
        alice@example.com,true
        bob@example.com,false
        """)

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{
          "type" => "mutes",
          "file" => upload
        })

      assert %{"type" => "mute", "queued" => 2} = json_response(conn, 200)
    end

    test "rejects unreadable account import uploads", %{conn: conn} do
      user = user_fixture()

      upload = %Plug.Upload{
        path:
          Path.join(System.tmp_dir!(), "missing-import-#{System.unique_integer([:positive])}"),
        filename: "following.csv",
        content_type: "text/csv"
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{
          "type" => "follows",
          "file" => upload
        })

      assert %{"error" => "import file could not be read"} = json_response(conn, 422)
    end

    test "rejects imports above the queue cap", %{conn: conn} do
      user = user_fixture()

      accounts =
        for index <- 1..(Elektrine.Accounts.AccountImportWorker.max_identifiers() + 1) do
          "person#{index}@example.com"
        end

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{
          "type" => "follows",
          "accounts" => accounts
        })

      assert %{"error" => "too many accounts in import"} = json_response(conn, 422)
    end

    test "imports domain blocks from exported domain lists", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{
          "type" => "domain_blocks",
          "data" => "Domain\nhttps://Example.COM/profile\n*.sub.example.net"
        })

      assert %{"type" => "domain_block", "queued" => 2} = json_response(conn, 200)

      assert Accounts.list_blocked_domains(user.id) |> Enum.sort() == [
               "*.sub.example.net",
               "example.com"
             ]
    end

    test "keeps plain comma-separated account lists working", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{
          "type" => "follows",
          "accounts" => "alice@example.com,bob@example.com"
        })

      assert %{"type" => "follow", "queued" => 2} = json_response(conn, 200)
    end

    test "defaults missing import type to follows for legacy clients", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> RelationshipImportController.create(%{"accounts" => []})

      assert %{"type" => "follow", "queued" => 0} = json_response(conn, 200)
    end

    test "dedicated follow import route queues follow imports", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/pleroma/follow_import", %{"accounts" => "alice@example.com"})

      assert %{"type" => "follow", "queued" => 1} = json_response(conn, 200)
    end

    test "dedicated mutes import route queues mute imports", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/pleroma/mutes_import", %{"data" => "alice@example.com"})

      assert %{"type" => "mute", "queued" => 1} = json_response(conn, 200)
    end

    test "dedicated blocks import route queues block imports", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/pleroma/blocks_import", %{"csv" => "Account address\nalice@example.com"})

      assert %{"type" => "block", "queued" => 1} = json_response(conn, 200)
    end
  end

  defp upload_fixture(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "relationship-import-#{System.unique_integer([:positive])}.csv"
      )

    File.write!(path, content)

    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: "following.csv", content_type: "text/csv"}
  end
end
