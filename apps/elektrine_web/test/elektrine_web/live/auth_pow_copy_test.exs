defmodule ElektrineWeb.AuthPowCopyTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Atomine.Credits
  alias Elektrine.AccountsFixtures

  setup do
    previous_config = Application.get_env(:elektrine, :atomine_pow, [])
    Application.put_env(:elektrine, :atomine_pow, difficulty: 8, skip_verification: false)

    on_exit(fn -> Application.put_env(:elektrine, :atomine_pow, previous_config) end)

    :ok
  end

  test "registration explains the automatic security check plainly", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/register")

    assert html =~ "Security check"
    assert html =~ "check level 8"
    assert html =~ "your browser does a short calculation"
    assert html =~ "without asking you to solve a puzzle"
    assert html =~ ~s(name="atomine_pow_token")
    refute html =~ "two-layer gate"
    refute html =~ "anonymous effort token"
  end

  test "password reset explains the automatic security check plainly", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/password/reset")

    assert html =~ "Security check"
    assert html =~ "check level 8"
    assert html =~ "your browser does a short calculation"
    assert html =~ "without asking you to solve a puzzle"
    assert html =~ ~s(name="atomine_pow_token")
    refute html =~ "two-layer gate"
    refute html =~ "anonymous effort token"
  end

  test "proofs page explains the automatic security check for credit proofs", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/proofs")

    assert html =~ "Proof of work"
    assert html =~ "pow-credit-atomine-pow"
    assert html =~ "Security check"
    assert html =~ "check level 8"
    assert html =~ "Your browser does a short calculation"
    assert html =~ "without asking you to solve a puzzle"
    refute html =~ "two-layer gate"
    refute html =~ "anonymous effort token"
  end

  test "proof-of-work credit claim requires the security check when enabled", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/proofs")

    html =
      view
      |> form("#pow-credit-form", %{})
      |> render_submit()

    assert html =~ "Security check failed. Please try again."
    assert Credits.balance(user.id, :atomine_credit) == 0
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
