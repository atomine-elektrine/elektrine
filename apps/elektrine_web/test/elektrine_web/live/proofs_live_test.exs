defmodule ElektrineWeb.ProofsLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Atomine.Credits
  alias Atomine.Personhood
  alias Elektrine.Accounts.User
  alias Elektrine.{AccountsFixtures, Repo}

  test "shows trust level, credit balances, and action prices", %{conn: conn} do
    user =
      AccountsFixtures.user_fixture()
      |> User.trust_level_changeset(%{trust_level: 2})
      |> Repo.update!()

    assert {:ok, _ledger_entry} = Credits.grant(user.id, :atomine_credit, 12, "test_grant")

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/proofs")

    assert html =~ "Credits and trust"
    assert html =~ "Trust level 2"
    assert html =~ "Atomine Credits"
    assert html =~ ~r/Atomine Credits.*12/s
    refute html =~ "DM Credits"
    refute html =~ "Email Credits"
    refute html =~ "Link Credits"
    refute html =~ "Signup Credits"
    refute html =~ "API Credits"
    refute html =~ "Invite Credits"
    assert html =~ "Ways to earn credits"
    assert html =~ "The same DNS name, profile, or page will not pay twice"
    assert html =~ "Proof of personhood/control"
    assert html =~ "5-15 Atomine Credits per verified proof"
    assert html =~ "Proof of work"
    assert html =~ "1 Atomine Credit per run, up to 20 per day."
    assert html =~ "DNS control proof"
    assert html =~ "10 Atomine Credits"
    assert html =~ "Web page proof"
    assert html =~ "8 Atomine Credits"
    assert html =~ "Social/profile proof"
    assert html =~ "GitHub account proof"
    assert html =~ "Planned: stake, reputation, service"
    assert html =~ "First DM"
    assert html =~ "External email"
    assert html =~ ~r/First DM.*1 Atomine Credit/s
    assert html =~ ~r/External email.*1 Atomine Credit/s
    assert html =~ "Higher-trust and admin accounts may not need credits for some actions."
  end

  test "earning proof actions do not use anchor targets", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/proofs")

    refute html =~ ~s(href="#proof-target")

    assert has_element?(
             view,
             ~s(button[phx-click="change_kind"][phx-value-proof-kind="dns"]),
             "DNS control proof"
           )
  end

  test "pending proofs show deterministic publication instructions", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, dns_proof} =
      Personhood.create_proof(user, %{
        kind: "dns",
        subject: "Example.COM."
      })

    {:ok, web_proof} =
      Personhood.create_proof(user, %{
        kind: "web",
        subject: "https://example.com/proof"
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/proofs")

    assert html =~ "Publish this signed claim"
    assert html =~ "DNS TXT record"
    assert html =~ "_atomine.example.com"
    assert html =~ dns_proof.challenge
    assert html =~ "Public web page"
    assert html =~ "https://example.com/proof"
    assert html =~ web_proof.challenge
    assert html =~ "validates the Atomine signature"
  end

  test "deleting a pending proof refreshes the nav badge", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, proof} =
      Personhood.create_proof(user, %{
        kind: "dns",
        subject: "pending-#{System.unique_integer([:positive])}.example.com",
        proof_mode: "snapshot"
      })

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/proofs")

    assert proof_nav_badges(html) == ["1"]

    html =
      view
      |> element("button[phx-click='delete_proof'][phx-value-id='#{proof.id}']")
      |> render_click()

    assert proof_nav_badges(html) == []
  end

  defp proof_nav_badges(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(nav.e-nav a[href="/account/proofs"] span.absolute))
    |> Enum.map(&(Floki.text(&1) |> String.trim()))
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
