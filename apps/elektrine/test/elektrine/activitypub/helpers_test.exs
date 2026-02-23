defmodule Elektrine.ActivityPub.HelpersTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.Helpers

  describe "get_follower_count/1" do
    test "handles numeric strings and collection totals" do
      metadata = %{
        "followers_count" => "12",
        "followers" => %{"totalItems" => "34"}
      }

      assert Helpers.get_follower_count(metadata) == 34
    end

    test "supports lemmy subscriber-style fields" do
      metadata = %{"subscribers" => 99, "member_count" => "17"}

      assert Helpers.get_follower_count(metadata) == 99
    end
  end

  describe "get_following_count/1" do
    test "handles string values and collection totals" do
      metadata = %{
        "following_count" => "6",
        "following" => %{"totalItems" => "9"}
      }

      assert Helpers.get_following_count(metadata) == 9
    end
  end

  describe "get_status_count/1" do
    test "supports posts aliases and outbox totals" do
      metadata = %{
        "postsCount" => "45",
        "outbox" => %{"totalItems" => "12"}
      }

      assert Helpers.get_status_count(metadata) == 45
    end

    test "falls back to outbox total when status fields are absent" do
      metadata = %{"outbox" => %{"totalItems" => 7}}

      assert Helpers.get_status_count(metadata) == 7
    end
  end
end
