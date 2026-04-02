defmodule ElektrineWeb.GalleryLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{AccountsFixtures, Messaging, Repo, Social, SocialFixtures}
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Messaging.Message

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp gallery_post_fixture(user, attrs) do
    conversation = attrs[:conversation] || SocialFixtures.timeline_conversation_fixture(user)
    title = attrs[:title] || "Gallery Post #{System.unique_integer([:positive])}"

    inserted_at =
      attrs[:inserted_at] ||
        NaiveDateTime.utc_now()
        |> NaiveDateTime.truncate(:second)
        |> NaiveDateTime.add(-System.unique_integer([:positive]), :second)

    updated_at = attrs[:updated_at] || inserted_at

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
        share_count: attrs[:share_count] || 0,
        inserted_at: inserted_at,
        updated_at: updated_at
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

  test "only liked photos render with active heart state", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    creator = AccountsFixtures.user_fixture()

    liked_photo =
      gallery_post_fixture(creator,
        title: "Liked in Gallery",
        content: "This one should render as liked"
      )

    unliked_photo =
      gallery_post_fixture(creator,
        title: "Not Liked in Gallery",
        content: "This one should stay unliked"
      )

    {:ok, _like} = Social.like_post(viewer.id, liked_photo.id)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/gallery")

    html = render_async(view)
    document = Floki.parse_document!(html)

    liked_button_classes =
      document
      |> Floki.find(~s(button[phx-click="like_photo"][phx-value-photo_id="#{liked_photo.id}"]))
      |> Floki.attribute("class")
      |> List.first()

    unliked_button_classes =
      document
      |> Floki.find(~s(button[phx-click="like_photo"][phx-value-photo_id="#{unliked_photo.id}"]))
      |> Floki.attribute("class")
      |> List.first()

    assert liked_button_classes =~ "btn-secondary"
    refute liked_button_classes =~ "btn-ghost"
    assert unliked_button_classes =~ "btn-ghost"
    refute unliked_button_classes =~ "btn-secondary"
  end

  test "gallery strips malformed html from captions and title fallbacks", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    creator = AccountsFixtures.user_fixture()

    gallery_post_fixture(creator,
      title: "",
      content:
        "<p>We&#39;re live now with No Agenda episode 1849 #@pocketnoagenda <a href=\"https://example.com/live\"",
      media_urls: ["/uploads/live-test.jpg"]
    )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/gallery")

    html = render_async(view)

    assert html =~ "We&#39;re live now with No Agenda episode 1849"
    assert html =~ "#@pocketnoagenda"
    refute html =~ "&lt;p&gt;We&amp;#39;re live now with No Agenda episode 1849 #@pocketnoagenda"
    refute html =~ "href=&quot;https://example.com/live&quot;"
  end

  test "remote gallery posts do not render profile URLs as creator names", %{conn: conn} do
    bad_display_name = "https://example.com/remote/zero@strelizia.net"

    photo =
      remote_gallery_post_fixture(
        username: "zero",
        domain: "strelizia.net",
        display_name: bad_display_name,
        title: "Federated Zero"
      )

    {:ok, view, _html} = live(conn, ~p"/gallery")
    html = render_async(view)

    assert html =~ photo.title
    assert html =~ "@zero@strelizia.net"
    refute html =~ bad_display_name
  end

  test "remote gallery posts render custom emojis in creator names", %{conn: conn} do
    photo =
      remote_gallery_post_fixture(
        username: "alice",
        domain: "remote.example",
        display_name: "Alice :blobcat:",
        title: "Emoji Gallery"
      )

    %CustomEmoji{}
    |> CustomEmoji.changeset(%{
      shortcode: "blobcat",
      image_url: "https://remote.example/emoji/blobcat.png",
      instance_domain: "remote.example",
      visible_in_picker: false,
      disabled: false
    })
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/gallery")
    html = render_async(view)

    assert html =~ photo.title
    assert html =~ "Alice"
    assert html =~ "custom-emoji"
    assert html =~ "blobcat.png"
  end

  test "gallery loads more photos through the infinite scroll event", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    creator = AccountsFixtures.user_fixture()

    for index <- 1..65 do
      timestamp =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.truncate(:second)
        |> NaiveDateTime.add(-index, :second)

      gallery_post_fixture(creator,
        title: "Paged Gallery #{index}",
        inserted_at: timestamp,
        updated_at: timestamp
      )
    end

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/gallery")

    initial_html = render_async(view)

    assert initial_html =~ "Paged Gallery 1"
    refute initial_html =~ "Paged Gallery 65"

    load_more_html = render_hook(view, "load-more", %{})

    assert load_more_html =~ "Paged Gallery 65"
  end

  defp remote_gallery_post_fixture(attrs) do
    unique = System.unique_integer([:positive])
    username = attrs[:username] || "remote#{unique}"
    domain = attrs[:domain] || "remote.example"
    activitypub_id = attrs[:activitypub_id] || "https://#{domain}/posts/#{unique}"

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://#{domain}/users/#{username}",
        username: username,
        domain: domain,
        display_name: attrs[:display_name],
        inbox_url: "https://#{domain}/inbox",
        public_key: "test-public-key-#{unique}"
      })
      |> Repo.insert!()

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: attrs[:content] || "Remote gallery caption",
        title: attrs[:title] || "Remote Gallery #{unique}",
        visibility: attrs[:visibility] || "public",
        post_type: "gallery",
        activitypub_id: activitypub_id,
        activitypub_url: attrs[:activitypub_url] || activitypub_id,
        remote_actor_id: remote_actor.id,
        media_urls: attrs[:media_urls] || ["https://#{domain}/media/#{unique}.jpg"]
      })

    Repo.preload(message, remote_actor: [])
  end
end
