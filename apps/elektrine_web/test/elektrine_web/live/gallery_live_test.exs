defmodule ElektrineWeb.GalleryLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{AccountsFixtures, Repo, Social, SocialFixtures}
  alias Elektrine.Messaging.Message

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp gallery_post_fixture(user, attrs) do
    conversation = attrs[:conversation] || SocialFixtures.timeline_conversation_fixture(user)
    title = attrs[:title] || "Gallery Post #{System.unique_integer([:positive])}"

    {:ok, message} =
      %Message{
        conversation_id: conversation.id,
        sender_id: user.id,
        content: attrs[:content] || "Gallery caption #{System.unique_integer([:positive])}",
        message_type: "image",
        media_urls: attrs[:media_urls] || ["/uploads/test-image.jpg"],
        visibility: attrs[:visibility] || "public",
        post_type: "gallery",
        title: title,
        category: attrs[:category] || "photography",
        like_count: attrs[:like_count] || 0,
        reply_count: attrs[:reply_count] || 0,
        share_count: attrs[:share_count] || 0
      }
      |> Repo.insert()

    Repo.preload(message, sender: [:profile], remote_actor: [])
  end

  test "signed-in users see collection filters and visible metadata", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    creator = AccountsFixtures.user_fixture()

    photo =
      gallery_post_fixture(creator,
        title: "Northern Lights Study",
        content: "Long exposure over the lake"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/gallery")

    html = render_async(view)

    assert has_element?(view, "h2", "Status")
    assert has_element?(view, "h2", "Recent")
    assert has_element?(view, "h2", "Quick Actions")
    assert has_element?(view, ~s(button[phx-value-filter="liked"]))
    assert has_element?(view, ~s(button[phx-value-filter="saved"]))
    assert html =~ photo.title
    assert html =~ (creator.display_name || creator.username)
  end

  test "search and saved mode narrow the gallery feed", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    creator = AccountsFixtures.user_fixture()

    saved_photo =
      gallery_post_fixture(creator,
        title: "Aurora Glass",
        content: "Green lights over frozen water"
      )

    other_photo =
      gallery_post_fixture(creator,
        title: "City Geometry",
        content: "Lines, glass, and concrete"
      )

    {:ok, _} = Social.save_post(viewer.id, saved_photo.id)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/gallery")

    search_html =
      view
      |> form("#gallery-search-form", query: "Aurora")
      |> render_change()

    assert search_html =~ saved_photo.title
    refute search_html =~ other_photo.title

    saved_html =
      view
      |> element("#gallery-filter-saved")
      |> render_click()

    assert saved_html =~ saved_photo.title
    refute saved_html =~ other_photo.title
  end
end
