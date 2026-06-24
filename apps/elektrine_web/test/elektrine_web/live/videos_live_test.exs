defmodule ElektrineSocialWeb.VideosLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{AccountsFixtures, Messaging, Repo, Social}
  alias Elektrine.ActivityPub.Actor
  alias ElektrineSocialWeb.VideosLive.Index

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

  test "videos page renders federated videos and excludes image-only posts", %{conn: conn} do
    video =
      remote_video_post_fixture(
        title: "PeerTube Federation Talk",
        media_url: "https://peertube.example/download/stream"
      )

    image = remote_image_post_fixture(title: "Remote Image Only")

    {:ok, view, _html} = live(conn, ~p"/videos")
    html = render_async(view)

    assert html =~ "Video Feed"
    assert html =~ video.title
    assert html =~ ~s(<video)
    assert html =~ ~s(src="https://peertube.example/download/stream")
    refute html =~ image.title
  end

  test "videos search and saved mode narrow the feed", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    saved_video =
      remote_video_post_fixture(
        title: "Aurora Encoding Notes",
        media_url: "https://video.example/media/aurora"
      )

    other_video =
      remote_video_post_fixture(
        title: "City Camera Walk",
        media_url: "https://video.example/media/city"
      )

    {:ok, _} = Social.save_post(viewer.id, saved_video.id)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/videos")

    search_html =
      view
      |> form("#videos-search-form", query: "Aurora")
      |> render_change()

    assert search_html =~ saved_video.title
    refute search_html =~ other_video.title

    saved_html =
      view
      |> element("#videos-filter-saved")
      |> render_click()

    assert saved_html =~ saved_video.title
    refute saved_html =~ other_video.title
  end

  test "video cards link to remote post detail", %{conn: conn} do
    video = remote_video_post_fixture(title: "Linked Video")

    {:ok, view, _html} = live(conn, ~p"/videos")
    html = render_async(view)

    assert html =~ video.title
    assert html =~ ~s(href="/remote/post/#{video.id}")
  end

  test "videos page renders posts when metadata has no attachment url", %{conn: conn} do
    video =
      remote_video_post_fixture(
        title: "Mastodon Video Attachment",
        media_url: "https://cdn.example/media/video.mp4",
        media_metadata: %{"type" => "Note"}
      )

    {:ok, view, _html} = live(conn, ~p"/videos")
    html = render_async(view)

    assert html =~ video.title
    assert html =~ ~s(src="https://cdn.example/media/video.mp4")
  end

  test "video actions reject malformed ids" do
    user = AccountsFixtures.user_fixture()
    socket = videos_socket(user)

    assert {:noreply, socket} =
             Index.handle_event("like_video", %{"video_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to like video"

    assert {:noreply, socket} =
             Index.handle_event("save_post", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to save video"

    assert {:noreply, socket} =
             Index.handle_event("unsave_post", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to unsave video"
  end

  defp remote_video_post_fixture(attrs) do
    unique = System.unique_integer([:positive])
    username = attrs[:username] || "video#{unique}"
    domain = attrs[:domain] || "peertube.example"
    activitypub_id = attrs[:activitypub_id] || "https://#{domain}/videos/watch/#{unique}"
    media_url = attrs[:media_url] || "https://#{domain}/download/#{unique}"

    remote_actor = remote_actor_fixture(username, domain)

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: attrs[:content] || "Remote video caption",
        title: attrs[:title] || "Remote Video #{unique}",
        visibility: attrs[:visibility] || "public",
        activitypub_id: activitypub_id,
        activitypub_url: attrs[:activitypub_url] || activitypub_id,
        remote_actor_id: remote_actor.id,
        media_urls: [media_url],
        media_metadata:
          attrs[:media_metadata] ||
            %{
              "type" => "Video",
              "thumbnail_url" => "https://#{domain}/lazy-static/previews/#{unique}.jpg",
              "media_attachments" => [
                %{
                  "type" => "video",
                  "mediaType" => "video/mp4",
                  "url" => media_url,
                  "preview_url" => "https://#{domain}/lazy-static/previews/#{unique}.jpg",
                  "width" => 1280,
                  "height" => 720
                }
              ]
            }
      })

    Repo.preload(message, remote_actor: [])
  end

  defp remote_image_post_fixture(attrs) do
    unique = System.unique_integer([:positive])
    username = attrs[:username] || "image#{unique}"
    domain = attrs[:domain] || "pixelfed.example"
    activitypub_id = attrs[:activitypub_id] || "https://#{domain}/p/#{unique}"

    remote_actor = remote_actor_fixture(username, domain)

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: attrs[:content] || "Remote image caption",
        title: attrs[:title] || "Remote Image #{unique}",
        visibility: attrs[:visibility] || "public",
        post_type: "gallery",
        activitypub_id: activitypub_id,
        activitypub_url: attrs[:activitypub_url] || activitypub_id,
        remote_actor_id: remote_actor.id,
        media_urls: attrs[:media_urls] || ["https://#{domain}/media/#{unique}.jpg"]
      })

    Repo.preload(message, remote_actor: [])
  end

  defp remote_actor_fixture(username, domain) do
    unique = System.unique_integer([:positive])

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      display_name: username,
      inbox_url: "https://#{domain}/inbox",
      public_key: "test-public-key-#{unique}"
    })
    |> Repo.insert!()
  end

  defp videos_socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        user_likes: MapSet.new(),
        user_saved_posts: MapSet.new(),
        video_posts: [],
        filtered_posts: [],
        current_filter: "discover",
        video_search: "",
        video_sort: "fresh",
        software_filter: "all"
      }
    }
  end
end
