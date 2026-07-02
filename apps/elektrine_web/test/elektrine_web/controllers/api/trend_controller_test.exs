defmodule ElektrineWeb.API.TrendControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures
  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Social.HashtagExtractor
  alias Elektrine.Social.HashtagFollows
  alias Elektrine.Social.Message
  alias ElektrineWeb.API.TrendController

  describe "tags/2" do
    test "returns trending hashtags by recent usage", %{conn: conn} do
      user = user_fixture()
      author = user_fixture()

      first = post_fixture(%{user: author, content: "first #kairo"})
      second = post_fixture(%{user: author, content: "second #kairo"})
      third = post_fixture(%{user: author, content: "third #phoenix"})

      HashtagExtractor.process_hashtags_for_message(first.id, ["kairo"])
      HashtagExtractor.process_hashtags_for_message(second.id, ["kairo"])
      HashtagExtractor.process_hashtags_for_message(third.id, ["phoenix"])
      assert {:ok, _follow} = HashtagFollows.follow_hashtag(user.id, "kairo")

      conn =
        conn
        |> assign(:current_user, user)
        |> TrendController.tags(%{"limit" => "1"})

      assert [
               %{
                 "name" => "kairo",
                 "following" => true,
                 "history" => [%{"uses" => 2, "accounts" => 1}]
               }
             ] = json_response(conn, 200)
    end
  end

  describe "statuses/2 and links/2" do
    test "returns trending statuses", %{conn: conn} do
      user = user_fixture()
      author = user_fixture()

      popular =
        post_fixture(%{
          user: author,
          visibility: "public",
          content: "popular status"
        })

      quiet =
        post_fixture(%{
          user: author,
          visibility: "public",
          content: "quiet status"
        })

      Message
      |> where([message], message.id == ^popular.id)
      |> Repo.update_all(set: [like_count: 10, reply_count: 4])

      Message
      |> where([message], message.id == ^quiet.id)
      |> Repo.update_all(set: [like_count: 1, reply_count: 0])

      status_conn =
        conn
        |> assign(:current_user, user)
        |> TrendController.statuses(%{"limit" => "1"})

      assert [%{"id" => id, "content" => "popular status"}] = json_response(status_conn, 200)
      assert id == to_string(popular.id)
    end

    test "returns trending links", %{conn: conn} do
      user = user_fixture()
      author = user_fixture()
      url = "https://example.com/launch"

      first = post_fixture(%{user: author, visibility: "public", content: "first link"})
      second = post_fixture(%{user: author, visibility: "public", content: "second link"})

      Message
      |> where([message], message.id in ^[first.id, second.id])
      |> Repo.update_all(set: [primary_url: url])

      link_conn =
        conn
        |> assign(:current_user, user)
        |> TrendController.links(%{"limit" => "1"})

      assert [
               %{
                 "url" => ^url,
                 "title" => ^url,
                 "type" => "link",
                 "history" => [%{"uses" => 2, "accounts" => 1}]
               }
             ] = json_response(link_conn, 200)
    end
  end
end
