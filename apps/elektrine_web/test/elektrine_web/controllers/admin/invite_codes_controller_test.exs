defmodule ElektrineWeb.Admin.InviteCodesControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.AdminSecurity

  setup do
    previous_trust_level = Elektrine.System.self_service_invite_min_trust_level()

    on_exit(fn ->
      Elektrine.System.set_self_service_invite_min_trust_level(previous_trust_level)
    end)

    :ok
  end

  describe "GET /pripyat/invite-codes" do
    test "renders the compact invite admin screen", %{conn: conn} do
      admin = admin_user_fixture()

      {:ok, _active_code} =
        Accounts.create_invite_code(%{
          code: "ACTIVE01",
          max_uses: 3,
          note: "Priority creator invite",
          created_by_id: admin.id
        })

      {:ok, _expired_code} =
        Accounts.create_invite_code(%{
          code: "EXPIRE01",
          max_uses: 1,
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          created_by_id: admin.id
        })

      {:ok, _inactive_code} =
        Accounts.create_invite_code(%{
          code: "PAUSED01",
          max_uses: 1,
          is_active: false,
          created_by_id: admin.id
        })

      {:ok, exhausted_code} =
        Accounts.create_invite_code(%{
          code: "FULL0001",
          max_uses: 1,
          created_by_id: admin.id
        })

      user = AccountsFixtures.user_fixture()
      assert {:ok, _invite_code} = Accounts.use_invite_code(exhausted_code.code, user.id)

      html =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/invite-codes")
        |> html_response(200)

      assert html =~ "Registration Mode"
      assert html =~ "Codes"
      assert html =~ "ACTIVE01"
      assert html =~ "EXPIRE01"
      assert html =~ "PAUSED01"
      assert html =~ "FULL0001"
      assert html =~ "Exhausted"
      assert html =~ "Priority creator invite"
      assert html =~ "Invite-only"
      assert html =~ "Self-Service Invite Access"
      assert html =~ "TL1+"
    end
  end

  describe "POST /pripyat/invite-codes/self-service-trust-level" do
    test "updates the self-service invite trust threshold", %{conn: conn} do
      admin = admin_user_fixture()
      request_path = "/pripyat/invite-codes/self-service-trust-level"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> AdminSecurity.initialize_admin_session(admin, auth_method: :passkey)

      action_grant = AdminSecurity.issue_action_grant(conn, admin, "POST", request_path)

      conn =
        post(conn, request_path, %{
          "_admin_action_grant" => action_grant,
          "min_trust_level" => "3"
        })

      assert redirected_to(conn) == "/pripyat/invite-codes"
      assert Elektrine.System.self_service_invite_min_trust_level() == 3
    end
  end

  describe "GET /pripyat/invite-codes/new" do
    test "renders the new invite form sections", %{conn: conn} do
      admin = admin_user_fixture()

      html =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/invite-codes/new")
        |> html_response(200)

      assert html =~ "Create Invite Code"
      assert html =~ "Code and Usage"
      assert html =~ "Expiration and Status"
      assert html =~ "Admin Note"
      assert html =~ "Internal Note"
    end
  end

  describe "GET /pripyat/invite-codes/:id/edit" do
    test "renders the invite snapshot and immutable code messaging", %{conn: conn} do
      admin = admin_user_fixture()

      {:ok, invite_code} =
        Accounts.create_invite_code(%{
          code: "EDIT0001",
          max_uses: 2,
          note: "Review this later",
          created_by_id: admin.id
        })

      html =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/invite-codes/#{invite_code.id}/edit")
        |> html_response(200)

      assert html =~ "Invite Snapshot"
      assert html =~ "What you can change"
      assert html =~ "EDIT0001"
      assert html =~ "Code values are immutable after creation"
    end
  end

  defp admin_user_fixture do
    user = AccountsFixtures.user_fixture()
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
