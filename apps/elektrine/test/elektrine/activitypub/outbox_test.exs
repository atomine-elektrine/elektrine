defmodule Elektrine.ActivityPub.OutboxTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Builder

  # Create a mock user struct for testing builders
  defp mock_user(username \\ "testuser") do
    %Elektrine.Accounts.User{
      id: 1,
      username: username,
      activitypub_enabled: true
    }
  end

  describe "EmojiReact activity builder" do
    test "builds correct EmojiReact activity structure" do
      user = mock_user()
      message_id = "https://remote.server/posts/123"

      activity = Builder.build_emoji_react_activity(user, message_id, ":thumbsup:")

      assert activity["type"] == "EmojiReact"
      assert activity["object"] == message_id
      assert activity["content"] == ":thumbsup:"
      assert String.contains?(activity["actor"], user.username)
      assert activity["@context"] == "https://www.w3.org/ns/activitystreams"
      assert String.starts_with?(activity["id"], "https://")
    end

    test "supports custom emoji with different content" do
      user = mock_user()
      message_id = "https://remote.server/posts/456"

      activity = Builder.build_emoji_react_activity(user, message_id, ":blobcat:")

      assert activity["content"] == ":blobcat:"
    end
  end

  describe "Undo Announce activity builder" do
    test "builds correct Undo Announce activity structure" do
      user = mock_user("boostuser")
      message_id = "https://remote.server/posts/456"

      announce = Builder.build_announce_activity(user, message_id)
      undo = Builder.build_undo_activity(user, announce)

      assert undo["type"] == "Undo"
      assert undo["object"]["type"] == "Announce"
      assert undo["object"]["object"] == message_id
      assert String.contains?(undo["actor"], user.username)
    end
  end

  describe "Flag (report) activity builder" do
    test "builds correct Flag activity structure with content" do
      user = mock_user("reporter")
      target_uri = "https://remote.server/users/baduser"
      content_uris = ["https://remote.server/posts/spam1", "https://remote.server/posts/spam2"]
      reason = "This user is posting spam"

      flag = Builder.build_flag_activity(user, target_uri, content_uris, reason)

      assert flag["type"] == "Flag"
      assert flag["@context"] == "https://www.w3.org/ns/activitystreams"
      assert String.contains?(flag["actor"], user.username)
      assert target_uri in flag["object"]
      assert Enum.all?(content_uris, fn uri -> uri in flag["object"] end)
      assert flag["content"] == reason
    end

    test "Flag activity without content has no content field" do
      user = mock_user("reporter")
      target_uri = "https://remote.server/users/baduser"

      flag = Builder.build_flag_activity(user, target_uri, [], nil)

      assert flag["type"] == "Flag"
      refute Map.has_key?(flag, "content")
    end

    test "Flag activity with empty content has no content field" do
      user = mock_user("reporter")
      target_uri = "https://remote.server/users/baduser"

      flag = Builder.build_flag_activity(user, target_uri, [], "")

      assert flag["type"] == "Flag"
      refute Map.has_key?(flag, "content")
    end

    test "Flag activity deduplicates object URIs" do
      user = mock_user("reporter")
      target_uri = "https://remote.server/users/baduser"

      flag = Builder.build_flag_activity(user, target_uri, [target_uri], "reason")

      # Should only have target_uri once
      assert Enum.count(flag["object"], fn uri -> uri == target_uri end) == 1
    end
  end
end
