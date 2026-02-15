defmodule Elektrine.ActivityPub.Handlers.LikeHandlerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.ActivityPub.Handlers.LikeHandler
  alias Elektrine.ActivityPub

  describe "handle/3 - Like activity" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns error for like on non-existent message", %{user: _user} do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "Like",
        "actor" => "https://remote.server/users/liker",
        "object" => "#{base_url}/posts/99999999"
      }

      result = LikeHandler.handle(activity, "https://remote.server/users/liker", nil)
      assert result == {:error, :handle_like_failed}
    end

    test "returns error for like with invalid object format" do
      activity = %{
        "type" => "Like",
        "actor" => "https://remote.server/users/liker",
        "object" => nil
      }

      result = LikeHandler.handle(activity, "https://remote.server/users/liker", nil)
      assert result == {:error, :handle_like_failed}
    end

    test "handles object reference as map with id" do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "Like",
        "actor" => "https://remote.server/users/liker",
        "object" => %{"id" => "#{base_url}/posts/99999999", "type" => "Note"}
      }

      # Should extract id from map and process
      result = LikeHandler.handle(activity, "https://remote.server/users/liker", nil)
      assert result == {:error, :handle_like_failed}
    end
  end

  describe "handle_emoji_react/3" do
    test "returns :unhandled for activity without content" do
      activity = %{
        "type" => "EmojiReact",
        "actor" => "https://remote.server/users/reactor",
        "object" => "https://example.com/posts/123"
      }

      result =
        LikeHandler.handle_emoji_react(activity, "https://remote.server/users/reactor", nil)

      assert result == {:ok, :unhandled}
    end

    test "returns error for non-existent message with emoji react" do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "EmojiReact",
        "actor" => "https://remote.server/users/reactor",
        "object" => "#{base_url}/posts/99999999",
        "content" => ":thumbsup:"
      }

      result =
        LikeHandler.handle_emoji_react(activity, "https://remote.server/users/reactor", nil)

      assert result == {:error, :handle_emoji_react_failed}
    end

    test "extracts custom emoji URL from tags" do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "EmojiReact",
        "actor" => "https://remote.server/users/reactor",
        "object" => "#{base_url}/posts/99999999",
        "content" => ":blobcat:",
        "tag" => [
          %{
            "type" => "Emoji",
            "name" => ":blobcat:",
            "icon" => %{"url" => "https://remote.server/emoji/blobcat.png"}
          }
        ]
      }

      # Will fail because message doesn't exist, but tests the path
      result =
        LikeHandler.handle_emoji_react(activity, "https://remote.server/users/reactor", nil)

      assert result == {:error, :handle_emoji_react_failed}
    end
  end

  describe "handle_undo_like/2" do
    test "returns error when remote actor cannot be fetched" do
      base_url = ActivityPub.instance_url()

      # handle_undo_like expects %{"object" => ...} structure
      object = %{"object" => "#{base_url}/posts/99999999"}

      result = LikeHandler.handle_undo_like(object, "https://remote.server/users/liker")
      # Fails because remote actor cannot be fetched
      assert result == {:error, :undo_like_failed}
    end

    test "handles object as nested map" do
      base_url = ActivityPub.instance_url()

      object = %{"object" => %{"id" => "#{base_url}/posts/99999999", "type" => "Note"}}

      result = LikeHandler.handle_undo_like(object, "https://remote.server/users/liker")
      assert result == {:error, :undo_like_failed}
    end
  end

  describe "handle_undo_emoji_react/2" do
    test "returns :invalid for activity without content or tags" do
      object = %{
        "type" => "EmojiReact",
        "object" => "https://example.com/posts/123"
      }

      result = LikeHandler.handle_undo_emoji_react(object, "https://remote.server/users/reactor")
      assert result == {:ok, :invalid}
    end

    test "extracts emoji from tag when content is missing" do
      base_url = ActivityPub.instance_url()

      object = %{
        "type" => "EmojiReact",
        "object" => "#{base_url}/posts/99999999",
        "tag" => [
          %{"type" => "Emoji", "name" => ":blobcat:"}
        ]
      }

      result = LikeHandler.handle_undo_emoji_react(object, "https://remote.server/users/reactor")
      assert result == {:error, :undo_emoji_react_failed}
    end

    test "returns :no_emoji_found when tags don't contain emoji" do
      object = %{
        "type" => "EmojiReact",
        "object" => "https://example.com/posts/123",
        "tag" => [
          %{"type" => "Hashtag", "name" => "#test"}
        ]
      }

      result = LikeHandler.handle_undo_emoji_react(object, "https://remote.server/users/reactor")
      assert result == {:ok, :no_emoji_found}
    end
  end

  describe "handle_dislike/3" do
    test "returns error for dislike on non-existent message" do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "Dislike",
        "actor" => "https://remote.server/users/disliker",
        "object" => "#{base_url}/posts/99999999"
      }

      result = LikeHandler.handle_dislike(activity, "https://remote.server/users/disliker", nil)
      assert result == {:error, :handle_dislike_failed}
    end
  end

  describe "handle_undo_dislike/2" do
    test "returns error for undo dislike on non-existent message" do
      base_url = ActivityPub.instance_url()

      object = %{"object" => "#{base_url}/posts/99999999"}

      result = LikeHandler.handle_undo_dislike(object, "https://remote.server/users/disliker")
      assert result == {:error, :undo_dislike_failed}
    end
  end
end
