defmodule ElektrineEmailWeb.Plugs.EmailOwnershipGuardTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.AccountsFixtures
  alias ElektrineEmailWeb.Plugs.EmailOwnershipGuard

  describe "check_message_access/1" do
    test "halts malformed id params instead of treating them as missing", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash([])
        |> Plug.Conn.assign(:current_user, user)
        |> Map.put(:params, %{"id" => "123abc"})
        |> EmailOwnershipGuard.call(action: :check_message_access)

      assert conn.halted
      assert get_resp_header(conn, "location") == ["/email"]
    end

    test "allows requests without a message id to continue", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash([])
        |> Plug.Conn.assign(:current_user, user)
        |> Map.put(:params, %{})
        |> EmailOwnershipGuard.call(action: :check_message_access)

      refute conn.halted
    end
  end
end
