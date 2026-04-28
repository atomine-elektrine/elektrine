defmodule ElektrineWeb.ProfileLiveDomainsTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures

  test "authenticated users can open the profile domains page and add a domain", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/domains")

    assert html =~ "Domains"
    assert html =~ "Profile Domains"
    assert html =~ "Email Domains"
    assert html =~ "Default Profile URL"
    assert html =~ "publish a followable ActivityPub alias"
    assert html =~ "That keeps the domain portable if the underlying hosting IPs change"

    unique = System.unique_integer([:positive])

    html =
      view
      |> form("form[phx-submit=create_profile_domain]", %{
        domain: "portfolio#{unique}.example.test"
      })
      |> render_submit()

    assert html =~ "portfolio#{unique}.example.test"
    assert html =~ "Ownership verification"
    assert html =~ "Copy public URL"
    assert html =~ "ActivityPub Alias"
    assert html =~ "@#{user.username}@portfolio#{unique}.example.test"
    assert html =~ "Copy ActivityPub alias"
    assert html =~ "Copy TXT host"
    assert html =~ "Copy TXT value"

    html =
      view
      |> form("form[phx-submit=create_email_domain]", %{
        domain: "mail#{unique}.example.test"
      })
      |> render_submit()

    assert html =~ "mail#{unique}.example.test"
    assert html =~ "#{user.username}@mail#{unique}.example.test"
    assert html =~ "Connected Email Domains"
    assert html =~ "Copy primary email address"
    assert html =~ "Sync DKIM"
  end

  defp log_in_user(conn, user) do
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
  end
end
