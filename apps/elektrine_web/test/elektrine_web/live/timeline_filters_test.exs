defmodule ElektrineWeb.TimelineFiltersTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Social

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "switching to posts view applies immediately when current filter is all", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, _regular_post} =
      Social.create_timeline_post(author.id, "Regular timeline post", visibility: "public")

    {:ok, _community_post} =
      Social.create_timeline_post(author.id, "Community timeline post",
        visibility: "public",
        community_actor_uri: "https://lemmy.world/c/elixir"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    assert render(view) =~ "2 shown"
    assert render(view) =~ "Regular timeline post"
    assert render(view) =~ "Community timeline post"

    render_hook(view, "filter_timeline", %{"filter" => "posts"})
    assert_patch(view, ~p"/timeline?filter=all&view=posts")

    html = render(view)

    assert html =~ "1 shown"
    assert html =~ "Regular timeline post"
    refute html =~ "Community timeline post"
  end
end
