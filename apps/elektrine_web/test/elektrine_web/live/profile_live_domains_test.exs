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
    assert html =~ "Built-in Profile URL"
    assert html =~ "Use a root domain like example.com for your public profile"
    assert html =~ "point the root host at the stable routing hostname"

    unique = System.unique_integer([:positive])

    html =
      view
      |> form("form[phx-submit=create_profile_domain]", %{
        domain: "portfolio#{unique}.example.test"
      })
      |> render_submit()

    assert html =~ "portfolio#{unique}.example.test"
    assert html =~ "DNS Setup"
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
    assert html =~ "Your Email Domains"
    assert html =~ "Copy primary email address"
    assert html =~ "Sync DKIM"
  end

  test "domain event handlers tolerate malformed ids", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/domains")

    assert render_hook(view, "toggle_per_site_identity", %{"id" => "1abc"}) =~
             "Per-site identity not found"

    assert render_hook(view, "verify_profile_domain", %{"id" => "1abc"}) =~
             "Profile domain not found"

    assert render_hook(view, "verify_email_domain", %{"id" => "1abc"}) =~
             "Email domain not found"
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
