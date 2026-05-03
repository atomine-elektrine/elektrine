defmodule Elektrine.ActivityPub.LemmyApiTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.LemmyApi

  describe "community_post_url?/1" do
    test "matches supported community post URL patterns" do
      assert LemmyApi.community_post_url?("https://lemmy.world/post/123")
      assert LemmyApi.community_post_url?("https://lemmy.world/post/123?sort=Top")
      assert LemmyApi.community_post_url?("https://piefed.social/c/tech/p/456")
      assert LemmyApi.community_post_url?("https://mbin.social/m/linux/t/789")
    end

    test "does not classify Bluesky post URLs as community posts" do
      refute LemmyApi.community_post_url?(
               "https://bsky.app/profile/alice.bsky.social/post/3l7nla7xq2s2d"
             )
    end
  end

  describe "fetch_post_comments_from_instance/5" do
    test "paginates comment bodies and preserves nested parent refs" do
      parent = self()

      request_fun = fn :get, url, _headers, _body, _opts ->
        send(parent, {:requested_url, url})

        page =
          url
          |> URI.parse()
          |> Map.get(:query)
          |> URI.decode_query()
          |> Map.fetch!("page")
          |> String.to_integer()

        comments =
          case page do
            1 -> Enum.map(1..100, &comment_view/1)
            2 -> Enum.map(101..105, &comment_view/1)
            _ -> []
          end

        {:ok, %Finch.Response{status: 200, body: Jason.encode!(%{"comments" => comments})}}
      end

      comments =
        LemmyApi.fetch_post_comments_from_instance(
          "lemmy.example",
          "42",
          "https://lemmy.example/post/42",
          105,
          request_fun: request_fun
        )

      assert length(comments) == 105
      assert Enum.at(comments, 0)["inReplyTo"] == "https://lemmy.example/post/42"
      assert Enum.at(comments, 100)["inReplyTo"] == "https://lemmy.example/comment/1"

      assert_received {:requested_url, page_1_url}
      assert page_1_url =~ "page=1"

      assert_received {:requested_url, page_2_url}
      assert page_2_url =~ "page=2"
    end
  end

  defp comment_view(id) do
    %{
      "comment" => %{
        "id" => id,
        "ap_id" => "https://lemmy.example/comment/#{id}",
        "content" => "comment #{id}",
        "published" => "2026-01-01T00:00:00Z",
        "path" => if(id == 1, do: "0.1", else: "0.1.#{id}")
      },
      "creator" => %{
        "actor_id" => "https://lemmy.example/u/alice",
        "name" => "alice"
      },
      "counts" => %{
        "score" => id,
        "upvotes" => id,
        "downvotes" => 0,
        "child_count" => 0
      }
    }
  end
end
