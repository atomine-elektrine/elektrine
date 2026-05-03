defmodule ElektrineWeb.ProofsLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Atomine.Credits
  alias Elektrine.Accounts.User
  alias Elektrine.{AccountsFixtures, Repo}

  test "shows trust level, credit balances, and action prices", %{conn: conn} do
    user =
      AccountsFixtures.user_fixture()
      |> User.trust_level_changeset(%{trust_level: 2})
      |> Repo.update!()

    assert {:ok, _ledger_entry} = Credits.grant(user.id, :atomine_credit, 12, "test_grant")
    assert {:ok, _ledger_entry} = Credits.grant(user.id, :dm_credit, 2, "test_grant")
    assert {:ok, _ledger_entry} = Credits.grant(user.id, :email_credit, 1, "test_grant")

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/proofs")

    assert html =~ "Account"
    assert html =~ "TL2"
    assert html =~ "Atomine Credits"
    assert html =~ ~r/Atomine Credits.*12/s
    assert html =~ "DM Credits"
    assert html =~ ~r/DM Credits.*2/s
    assert html =~ "Email Credits"
    assert html =~ ~r/Email Credits.*1/s
    refute html =~ "Link Credits"
    refute html =~ "Signup Credits"
    refute html =~ "API Credits"
    refute html =~ "Invite Credits"
    assert html =~ "How to earn credits"
    assert html =~ "Proof of personhood/control"
    assert html =~ "5-15 Atomine Credits per verified proof"
    assert html =~ "Planned: stake, work, reputation, service"
    assert html =~ "First DM"
    assert html =~ "External email"
    assert html =~ "1 Atomine Credit / 1 DM Credit"
    assert html =~ "5 Atomine Credits / 1 Email Credit"
    assert html =~ "Gates are currently off."
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
