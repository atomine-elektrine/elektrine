defmodule Elektrine.ActivityPub.HandlerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Handler

  describe "extract_local_mentions/1" do
    test "extracts username from z.org mention" do
      object = %{
        "tag" => [
          %{
            "type" => "Mention",
            "href" => "https://z.org/users/testuser",
            "name" => "@testuser@z.org"
          }
        ]
      }

      result = Handler.extract_local_mentions(object)
      assert result == ["testuser"]
    end

    test "extracts username from elektrine.com mention" do
      object = %{
        "tag" => [
          %{
            "type" => "Mention",
            "href" => "https://elektrine.com/users/testuser",
            "name" => "@testuser@elektrine.com"
          }
        ]
      }

      result = Handler.extract_local_mentions(object)
      assert result == ["testuser"]
    end

    test "ignores remote mentions" do
      object = %{
        "tag" => [
          %{
            "type" => "Mention",
            "href" => "https://mastodon.social/users/someuser",
            "name" => "@someuser@mastodon.social"
          }
        ]
      }

      result = Handler.extract_local_mentions(object)
      assert result == []
    end

    test "extracts multiple local mentions from both domains" do
      object = %{
        "tag" => [
          %{
            "type" => "Mention",
            "href" => "https://z.org/users/alice",
            "name" => "@alice@z.org"
          },
          %{
            "type" => "Mention",
            "href" => "https://elektrine.com/users/bob",
            "name" => "@bob@elektrine.com"
          },
          %{
            "type" => "Mention",
            "href" => "https://mastodon.social/users/charlie",
            "name" => "@charlie@mastodon.social"
          },
          %{
            "type" => "Hashtag",
            "href" => "https://z.org/tags/test",
            "name" => "#test"
          }
        ]
      }

      result = Handler.extract_local_mentions(object)
      assert Enum.sort(result) == ["alice", "bob"]
    end

    test "handles empty tags" do
      object = %{"tag" => []}
      result = Handler.extract_local_mentions(object)
      assert result == []
    end

    test "handles missing tags" do
      object = %{}
      result = Handler.extract_local_mentions(object)
      assert result == []
    end

    test "handles nil tags" do
      object = %{"tag" => nil}
      result = Handler.extract_local_mentions(object)
      assert result == []
    end
  end
end
