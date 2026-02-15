defmodule ElektrineWeb.API.EmailControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias ElektrineWeb.Plugs.APIAuth

  setup do
    user = AccountsFixtures.user_fixture()
    {:ok, token} = APIAuth.generate_token(user.id)
    %{user: user, token: token}
  end

  defp auth_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  describe "GET /api/emails" do
    test "returns emails list", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/emails")

      response = json_response(conn, 200)
      assert is_list(response["emails"]) or is_list(response)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/emails")
      assert conn.status == 401
    end
  end

  describe "GET /api/emails/counts" do
    test "returns email counts", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/emails/counts")

      response = json_response(conn, 200)
      assert is_map(response)
    end
  end

  describe "GET /api/emails/:id" do
    test "returns 404 for non-existent email", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/emails/999999")

      assert conn.status in [403, 404]
    end

    test "returns 400 for invalid email id", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/emails/not-a-number")

      response = json_response(conn, 400)
      assert response["error"] == "Invalid email id"
    end
  end

  describe "DELETE /api/emails/:id" do
    test "returns error for non-existent email", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> delete("/api/emails/999999")

      assert conn.status in [403, 404]
    end
  end

  describe "GET /api/emails/search" do
    test "searches emails", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/emails/search", %{q: "test"})

      response = json_response(conn, 200)
      assert is_list(response["emails"]) or is_list(response)
    end
  end

  describe "GET /api/emails/:id/attachments" do
    test "supports map-based attachment storage", %{conn: conn, token: token, user: user} do
      mailbox = Email.get_user_mailbox(user.id)

      {:ok, message} =
        Email.create_message(%{
          from: "sender@example.com",
          to: mailbox.email,
          subject: "Message with attachment",
          text_body: "See attachment",
          message_id: "attachment-test-#{System.unique_integer([:positive])}@example.com",
          mailbox_id: mailbox.id,
          attachments: %{
            "att-1" => %{
              "filename" => "report.pdf",
              "content_type" => "application/pdf",
              "size" => 123
            }
          }
        })

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/emails/#{message.id}/attachments")

      response = json_response(conn, 200)
      assert [%{"id" => "att-1", "filename" => "report.pdf"}] = response["attachments"]
    end
  end
end
