defmodule ElektrineWeb.SubscribeLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{AccountsFixtures, Repo}
  alias Elektrine.Subscriptions.{Product, Subscription}

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

  test "shows a pending state after checkout success until webhook confirmation", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    product =
      Repo.insert!(%Product{
        name: "VPN",
        slug: "vpn",
        description: "Private network access",
        currency: "usd",
        active: true,
        monthly_price_cents: 1900,
        yearly_price_cents: 19_000,
        stripe_monthly_price_id: "price_month",
        stripe_yearly_price_id: "price_year"
      })

    Repo.insert!(%Subscription{
      user_id: user.id,
      product: product.slug,
      status: "incomplete"
    })

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/subscribe/#{product.slug}?success=true")

    assert html =~ "access is still syncing from Stripe"
    assert render(view) =~ "Processing..."
  end

  test "renders one-time purchase copy for one-time products", %{conn: conn} do
    product =
      Repo.insert!(%Product{
        name: "Registration",
        slug: "registration",
        description: "Pay once to register",
        billing_type: "one_time",
        currency: "usd",
        active: true,
        one_time_price_cents: 500,
        stripe_one_time_price_id: "price_once"
      })

    {:ok, _view, html} = live(conn, ~p"/subscribe/#{product.slug}")

    assert html =~ "One-time Purchase"
    assert html =~ "Log in to Purchase"
    assert html =~ "$5.00"
  end
end
