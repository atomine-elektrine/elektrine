defmodule ElektrineWeb.Admin.CommunitiesControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging.Conversation
  alias Elektrine.Repo

  describe "GET /pripyat/communities" do
    test "renders with fallback timezone when admin timezone is nil", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()

      {:ok, _community} =
        %Conversation{}
        |> Conversation.changeset(%{
          name: "timezone-test-#{System.unique_integer([:positive])}",
          type: "community",
          creator_id: admin.id,
          is_public: true,
          last_message_at: DateTime.utc_now()
        })
        |> Repo.insert()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/communities")

      assert html_response(conn, 200) =~ "Community Management"
    end
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

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
