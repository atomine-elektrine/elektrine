defmodule Elektrine.Messaging.SocialMessageSecurityTest do
  use ExUnit.Case, async: true

  alias Elektrine.Social.Message

  describe "changeset URL security" do
    test "rejects unsafe primary URLs for link posts" do
      for url <- [
            "javascript:alert(1)",
            "//evil.example/post",
            "https://user:pass@example.com/post",
            "https://example.com/\r\nx-injected: yes"
          ] do
        changeset =
          Message.changeset(%Message{}, %{
            conversation_id: 1,
            sender_id: 1,
            post_type: "link",
            primary_url: url
          })

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :primary_url)
      end
    end

    test "accepts valid primary URLs for link posts" do
      changeset =
        Message.changeset(%Message{}, %{
          conversation_id: 1,
          sender_id: 1,
          post_type: "link",
          primary_url: "https://example.com/post"
        })

      assert changeset.valid?
    end

    test "rejects local media keys with traversal after the owner prefix" do
      changeset =
        Message.changeset(%Message{}, %{
          conversation_id: 1,
          sender_id: 42,
          media_urls: ["/uploads/timeline-attachments/42_../secret.png"]
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :media_urls)
    end

    test "rejects external media URLs with userinfo or untrusted hosts" do
      for url <- [
            "https://user:pass@avatars.githubusercontent.com/u/1",
            "https://evil.example/image.png"
          ] do
        changeset =
          Message.changeset(%Message{}, %{
            conversation_id: 1,
            sender_id: 42,
            media_urls: [url]
          })

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :media_urls)
      end
    end

    test "accepts owned local media keys and trusted external media URLs" do
      changeset =
        Message.changeset(%Message{}, %{
          conversation_id: 1,
          sender_id: 42,
          media_urls: [
            "/uploads/timeline-attachments/42_photo.png",
            "https://avatars.githubusercontent.com/u/1"
          ]
        })

      assert changeset.valid?
    end
  end
end
