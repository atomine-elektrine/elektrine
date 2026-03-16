defmodule ElektrineWeb.ProfileLiveDomainsTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures

  test "authenticated users can open the profile domains page and add a domain", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/profile/domains")

    assert html =~ "Profile Domains"
    assert html =~ "Default Profile URL"

    unique = System.unique_integer([:positive])

    html =
      view
      |> form("form[phx-submit=create_custom_domain]", %{
        domain: "portfolio#{unique}.example.test"
      })
      |> render_submit()

    assert html =~ "portfolio#{unique}.example.test"
    assert html =~ "Ownership verification"
  end

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
