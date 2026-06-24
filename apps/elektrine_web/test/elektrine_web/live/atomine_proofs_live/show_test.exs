defmodule ElektrineWeb.AtomineProofsLive.ShowTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{Accounts, Profiles}
  alias Elektrine.AccountsFixtures

  test "renders the proofs search entry page without a handle", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/proofs")

    assert html =~ "Atomine Proofs"
    assert html =~ "Find public proofs"
    assert html =~ "search public accounts"
  end

  test "search page shows matching public users only", %{conn: conn} do
    unique = System.unique_integer([:positive])

    public_user =
      AccountsFixtures.user_fixture(%{
        username: "graphfinder#{unique}",
        display_name: "Graph Finder #{unique}"
      })

    _private_user =
      AccountsFixtures.user_fixture(%{
        username: "graphhidden#{unique}",
        profile_visibility: "private"
      })

    {:ok, _view, html} = live(conn, ~p"/proofs?q=graph")

    assert html =~ "@#{public_user.handle}"
    refute html =~ "graphhidden#{unique}"
  end

  test "renders the standalone public proofs page", %{conn: conn} do
    unique = System.unique_integer([:positive])

    inviter = AccountsFixtures.user_fixture(%{username: "liveinviter#{unique}"})
    subject = AccountsFixtures.user_fixture(%{username: "livesubject#{unique}"})
    follower = AccountsFixtures.user_fixture(%{username: "livefollower#{unique}"})

    {:ok, invite_code} =
      Accounts.create_invite_code(%{
        code: "LIVEAA#{unique}",
        created_by_id: inviter.id
      })

    {:ok, _used_code} = Accounts.use_invite_code(invite_code.code, subject.id)
    {:ok, _follow} = Profiles.follow_user(follower.id, subject.id)
    {:ok, subject} = Accounts.admin_update_user(subject, %{trust_level: 1})

    {:ok, _view, html} = live(conn, ~p"/proofs/#{subject.handle}")

    assert html =~ "Atomine Proofs"
    assert html =~ "Proofs for"
    assert html =~ ".#{Elektrine.Domains.default_profile_domain()}"
    assert html =~ "domain:"
    assert html =~ ".well-known/atomine"
    assert html =~ "@#{subject.handle}"
    assert html =~ "proof-graph-shell"
    assert html =~ "data-graph="
  end

  test "shows the privacy state when the graph is not public", %{conn: conn} do
    user =
      AccountsFixtures.user_fixture(%{
        username: "privategraph#{System.unique_integer([:positive])}",
        profile_visibility: "private"
      })

    {:ok, _view, html} = live(conn, ~p"/proofs/#{user.handle}")

    assert html =~ "This account is not public"
  end
end
