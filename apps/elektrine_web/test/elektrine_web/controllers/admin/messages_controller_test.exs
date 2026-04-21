defmodule ElektrineEmailWeb.Admin.MessagesControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Ecto.Query

  alias Elektrine.{Accounts, AuditLog, Repo}
  alias Elektrine.AccountsFixtures
  alias Elektrine.EmailFixtures
  alias ElektrineWeb.AdminSecurity

  describe "admin email view logging" do
    test "logs standard admin message view", %{conn: conn} do
      %{admin: admin, owner: owner, message: message} = admin_message_fixture()
      request_path = "/pripyat/messages/#{message.id}/view"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)

      conn =
        get(conn, request_path, %{
          "_admin_action_grant" => grant_read_access(conn, admin, request_path)
        })

      assert html_response(conn, 200) =~ "Message Details"

      log = latest_view_email_log(admin.id, message.id)
      assert log.resource_type == "email_message"
      assert log.target_user_id == owner.id
      assert log.details["view_format"] == "html"
      assert log.details["route_context"] == "admin_messages"
    end

    test "logs user-scoped message view", %{conn: conn} do
      %{admin: admin, owner: owner, message: message} = admin_message_fixture()
      request_path = "/pripyat/users/#{owner.id}/messages/#{message.id}"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)

      conn =
        get(conn, request_path, %{
          "_admin_action_grant" => grant_read_access(conn, admin, request_path)
        })

      assert html_response(conn, 200) =~ "Message Details"

      log = latest_view_email_log(admin.id, message.id)
      assert log.resource_type == "email_message"
      assert log.target_user_id == owner.id
      assert log.details["view_format"] == "html"
      assert log.details["route_context"] == "user_scoped"
    end

    test "logs raw admin message view", %{conn: conn} do
      %{admin: admin, owner: owner, message: message} = admin_message_fixture()
      request_path = "/pripyat/messages/#{message.id}/raw"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)

      conn =
        get(conn, request_path, %{
          "_admin_action_grant" => grant_read_access(conn, admin, request_path)
        })

      assert response(conn, 200) =~ "EMAIL CONTENT"

      log = latest_view_email_log(admin.id, message.id)
      assert log.resource_type == "email_message"
      assert log.target_user_id == owner.id
      assert log.details["view_format"] == "raw"
      assert log.details["route_context"] == "admin_messages"
    end

    test "logs user-scoped raw message view", %{conn: conn} do
      %{admin: admin, owner: owner, message: message} = admin_message_fixture()
      request_path = "/pripyat/users/#{owner.id}/messages/#{message.id}/raw"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)

      conn =
        get(conn, request_path, %{
          "_admin_action_grant" => grant_read_access(conn, admin, request_path)
        })

      assert response(conn, 200) =~ "EMAIL CONTENT"

      log = latest_view_email_log(admin.id, message.id)
      assert log.resource_type == "email_message"
      assert log.target_user_id == owner.id
      assert log.details["view_format"] == "raw"
      assert log.details["route_context"] == "user_scoped"
    end

    test "logs iframe message view", %{conn: conn} do
      %{admin: admin, owner: owner, message: message} = admin_message_fixture()
      request_path = "/pripyat/messages/#{message.id}/iframe"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)

      conn =
        get(conn, request_path, %{
          "_admin_action_grant" => grant_read_access(conn, admin, request_path)
        })

      assert response(conn, 200) =~ "<p>Test body content</p>"

      log = latest_view_email_log(admin.id, message.id)
      assert log.resource_type == "email_message"
      assert log.target_user_id == owner.id
      assert log.details["view_format"] == "iframe"
      assert log.details["route_context"] == "admin_messages"
    end

    test "blocks message view without a read grant", %{conn: conn} do
      %{admin: admin, message: message} = admin_message_fixture()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/messages/#{message.id}/view")

      assert html_response(conn, 403) =~ "403"
    end
  end

  defp admin_message_fixture do
    admin = AccountsFixtures.user_fixture() |> make_admin()
    owner = AccountsFixtures.user_fixture()
    mailbox = EmailFixtures.mailbox_fixture(%{user_id: owner.id})
    message = EmailFixtures.message_fixture(%{mailbox_id: mailbox.id, to: mailbox.email})

    %{admin: admin, owner: owner, mailbox: mailbox, message: message}
  end

  defp latest_view_email_log(admin_id, message_id) do
    Repo.one!(
      from(a in AuditLog,
        where:
          a.admin_id == ^admin_id and
            a.action == "view_email" and
            a.resource_type == "email_message" and
            a.resource_id == ^message_id,
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
    Map.put(conn, :host, "example.com")
  end

  defp log_in_as(conn, user) do
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
    |> AdminSecurity.initialize_admin_session(user, auth_method: :passkey)
  end

  defp grant_read_access(conn, admin, request_path) do
    AdminSecurity.issue_action_grant(conn, admin, "GET", request_path)
  end
end
