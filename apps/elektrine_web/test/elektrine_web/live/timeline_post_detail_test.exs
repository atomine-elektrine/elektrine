defmodule ElektrineWeb.TimelinePostDetailTest do
  use ElektrineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social

  describe "image posts on timeline detail page" do
    test "renders an image-only local post", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, post} =
        Social.create_timeline_post(user.id, "",
          visibility: "public",
          media_urls: ["timeline-attachments/test.jpg"]
        )

      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/timeline/post/#{post.id}")
      assert redirect_to == ~p"/remote/post/#{post.id}"

      {:ok, _view, html} = live(conn, redirect_to)

      assert html =~ "/uploads/timeline-attachments/test.jpg"
    end

    test "does not crash when media_urls contains blank entries", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, post} =
        Social.create_timeline_post(user.id, "",
          visibility: "public",
          media_urls: ["timeline-attachments/test.jpg"]
        )

      Repo.update_all(
        from(m in Message, where: m.id == ^post.id),
        set: [media_urls: ["", "timeline-attachments/test.jpg"]]
      )

      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/timeline/post/#{post.id}")
      assert redirect_to == ~p"/remote/post/#{post.id}"

      {:ok, _view, html} = live(conn, redirect_to)

      assert html =~ "/uploads/timeline-attachments/test.jpg"
    end

    test "does not crash when cached replies metadata is a URL string", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, post} =
        Social.create_timeline_post(user.id, "Cached post with replies URL", visibility: "public")

      activitypub_id = "https://popbob.wtf/notes/aio1kmd9jaat9rgd"

      Repo.update_all(
        from(m in Message, where: m.id == ^post.id),
        set: [
          activitypub_id: activitypub_id,
          media_metadata: %{
            "replies" => "#{activitypub_id}/replies",
            "replies_count" => "7"
          }
        ]
      )

      encoded_id = URI.encode_www_form(activitypub_id)
      assert {:ok, _view, _html} = live(conn, ~p"/remote/post/#{encoded_id}")
    end
  end
end
