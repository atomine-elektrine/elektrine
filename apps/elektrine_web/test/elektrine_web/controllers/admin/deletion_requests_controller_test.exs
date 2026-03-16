defmodule ElektrineWeb.Admin.DeletionRequestsControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Ecto.Query

  alias Elektrine.{Accounts, AuditLog, Repo}
  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.AdminSecurity

  describe "GET /pripyat/deletion-requests/:id" do
    test "renders with fallback timezone when admin timezone is nil", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()
      user = AccountsFixtures.user_fixture()
      {:ok, request} = Accounts.create_deletion_request(user, %{reason: "Delete me"})

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/deletion-requests/#{request.id}")

      assert html_response(conn, 200) =~ "Account Deletion Request"
      assert html_response(conn, 200) =~ "Delete me"
    end
  end

  describe "POST /pripyat/deletion-requests/:id/approve" do
    test "approves the request and records audit details without a deleted-user FK", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()
      user = AccountsFixtures.user_fixture()
      {:ok, request} = Accounts.create_deletion_request(user, %{reason: "Delete me"})
      request_path = "/pripyat/deletion-requests/#{request.id}/approve"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> AdminSecurity.initialize_admin_session(admin, auth_method: :passkey)

      action_grant = AdminSecurity.issue_action_grant(conn, admin, "POST", request_path)

      conn =
        post(conn, request_path, %{
          "_admin_action_grant" => action_grant,
          "admin_notes" => "Approved"
        })

      assert redirected_to(conn) == "/pripyat/deletion-requests"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Account deletion request approved and user account deleted."

      assert Repo.get(Accounts.User, user.id) == nil

      log = latest_deletion_request_log(admin.id, request.id)
      assert log.target_user_id == nil
      assert log.details["deleted_user_id"] == user.id
      assert log.details["deleted_username"] == user.username
      assert log.details["admin_notes"] == "Approved"
    end
  end

  defp latest_deletion_request_log(admin_id, request_id) do
    Repo.one!(
      from(a in AuditLog,
        where:
          a.admin_id == ^admin_id and
            a.action == "approve" and
            a.resource_type == "deletion_request" and
            fragment("?->>'request_id' = ?", a.details, ^to_string(request_id)),
        order_by: [desc: a.inserted_at],
        limit: 1
      )
    )
  end

  defp make_admin(user) do
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "elektrine.com")
  end

  defp log_in_as(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)
    now = System.system_time(:second)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
  end
end
