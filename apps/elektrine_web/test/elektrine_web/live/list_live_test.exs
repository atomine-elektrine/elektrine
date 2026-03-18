defmodule ElektrineWeb.ListLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{AccountsFixtures, Social}

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp list_fixture(owner, attrs) do
    {:ok, list} =
      Social.create_list(%{
        user_id: owner.id,
        name: attrs[:name] || "List #{System.unique_integer([:positive])}",
        description: attrs[:description] || "",
        visibility: attrs[:visibility] || "private"
      })

    Enum.each(attrs[:members] || [], fn member ->
      {:ok, _member} = Social.add_to_list(list.id, %{user_id: member.id})
    end)

    Social.get_user_list(owner.id, list.id) || Social.get_public_list(list.id)
  end

  test "my lists search matches member names and visibility filters narrow the grid", %{
    conn: conn
  } do
    viewer = AccountsFixtures.user_fixture()
    designer = AccountsFixtures.user_fixture(%{username: "designhelper"})
    ops_member = AccountsFixtures.user_fixture(%{username: "opssignal"})

    design_list =
      list_fixture(viewer,
        name: "Design Crew",
        description: "Visual systems and UI review",
        visibility: "public",
        members: [designer]
      )

    ops_list =
      list_fixture(viewer,
        name: "Ops Watch",
        description: "Incident coordination",
        visibility: "private",
        members: [ops_member]
      )

    friends_list =
      list_fixture(viewer,
        name: "Friends Circle",
        description: "Neighbors and mutuals",
        visibility: "public"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/lists")

    assert has_element?(view, "h1", "Lists")

    view
    |> form("#my-lists-search-form", %{"query" => "opssignal"})
    |> render_change()

    assert has_element?(view, ~s(a[href="/lists/#{ops_list.id}"]), "Ops Watch")
    refute has_element?(view, ~s(a[href="/lists/#{design_list.id}"]), "Design Crew")
    refute has_element?(view, ~s(a[href="/lists/#{friends_list.id}"]), "Friends Circle")

    view
    |> element(~s(button[phx-click="clear_my_lists_search"]))
    |> render_click()

    view
    |> element(~s(button[phx-value-visibility="public"]))
    |> render_click()

    assert has_element?(view, ~s(a[href="/lists/#{design_list.id}"]), "Design Crew")
    assert has_element?(view, ~s(a[href="/lists/#{friends_list.id}"]), "Friends Circle")
    refute has_element?(view, ~s(a[href="/lists/#{ops_list.id}"]), "Ops Watch")
  end

  test "discover excludes the viewer's own public lists and can be searched", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture(%{username: "curator"})

    own_public =
      list_fixture(viewer,
        name: "My Public Radar",
        description: "Should stay out of discover",
        visibility: "public"
      )

    community_list =
      list_fixture(other_user,
        name: "Community Picks",
        description: "Writers and maintainers",
        visibility: "public"
      )

    art_list =
      list_fixture(other_user,
        name: "Local Art Watch",
        description: "Illustrators and photographers",
        visibility: "public"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/lists")

    view
    |> element(~s(button[phx-value-mode="discover"]))
    |> render_click()

    assert has_element?(view, ~s(a[href="/lists/#{community_list.id}"]), "Community Picks")
    assert has_element?(view, ~s(a[href="/lists/#{art_list.id}"]), "Local Art Watch")
    refute has_element?(view, ~s(a[href="/lists/#{own_public.id}"]), "My Public Radar")

    view
    |> form("#discover-lists-search-form", %{"query" => "art"})
    |> render_change()

    assert has_element?(view, ~s(a[href="/lists/#{art_list.id}"]), "Local Art Watch")
    refute has_element?(view, ~s(a[href="/lists/#{community_list.id}"]), "Community Picks")
    refute has_element?(view, ~s(a[href="/lists/#{own_public.id}"]), "My Public Radar")
  end

  test "create form keeps entered values when creation fails", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    _existing_list =
      list_fixture(viewer,
        name: "Release Radar",
        description: "A feed for launch updates",
        visibility: "private"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/lists")

    failure_html =
      view
      |> form("#list-create-form", %{
        "name" => "Release Radar",
        "description" => "Duplicate attempt description",
        "visibility" => "public"
      })
      |> render_submit()

    assert failure_html =~ "has already been taken"
    assert failure_html =~ "Duplicate attempt description"
    assert has_element?(view, ~s(#list-create-form input[name="name"][value="Release Radar"]))

    assert has_element?(
             view,
             ~s(#list-create-form textarea[name="description"]),
             "Duplicate attempt description"
           )

    assert has_element?(view, ~s(#list-create-form option[value="public"][selected]))
  end

  test "liked posts can be unliked from a list timeline", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    list = list_fixture(viewer, members: [author])

    {:ok, post} =
      Social.create_timeline_post(author.id, "List unlike target", visibility: "public")

    {:ok, _like} = Social.like_post(viewer.id, post.id)

    {:ok, view, html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/lists/#{list.id}")

    assert html =~ "List unlike target"
    assert Social.user_liked_post?(viewer.id, post.id)

    render_hook(view, "unlike_post", %{"message_id" => Integer.to_string(post.id)})

    refute Social.user_liked_post?(viewer.id, post.id)
  end
end
