defmodule Elektrine.ActivityPub.Handlers.LikeHandlerTest do
  use Elektrine.DataCase, async: true

  if not Code.ensure_loaded?(Elektrine.Social.Hashtag) do
    @moduletag skip: "requires :elektrine_social"
  end

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.LikeHandler
  alias Elektrine.Messaging.FederatedDislike
  alias Elektrine.Messaging.FederatedLike
  alias Elektrine.Messaging.MessageReaction
  alias Elektrine.Messaging
  alias Elektrine.Repo

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

    test "matches a cached federated post by activitypub URL variant" do
      liker = remote_actor_fixture("liker")
      author = remote_actor_fixture("author")
      canonical_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"
      object_url = "#{canonical_id}/view"

      assert {:ok, _message} =
               Messaging.create_federated_message(%{
                 content: "Remote post",
                 visibility: "public",
                 activitypub_id: canonical_id,
                 activitypub_url: object_url,
                 federated: true,
                 remote_actor_id: author.id,
                 inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
               })

      activity = %{
        "type" => "Like",
        "actor" => liker.uri,
        "object" => object_url
      }

      assert {:ok, :liked} = LikeHandler.handle(activity, liker.uri, nil)
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

    test "hydrates wrapped public objects when the Create wrapper carries the audience" do
      reactor = remote_actor_fixture("reactor")
      author = remote_actor_fixture("wrappedauthor")
      wrapper_uri = "https://example.com/activities/#{System.unique_integer([:positive])}"
      object_id = "https://example.com/objects/#{System.unique_integer([:positive])}"

      wrapper_object = %{
        "id" => wrapper_uri,
        "type" => "Create",
        "actor" => author.uri,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "object" => %{
          "id" => object_id,
          "type" => "Note",
          "content" => "<p>Wrapped note</p>",
          "attributedTo" => author.uri,
          "to" => [],
          "cc" => []
        }
      }

      assert {:ok, _cached_wrapper} =
               Elektrine.AppCache.get_object(wrapper_uri, fn -> {:ok, wrapper_object} end)

      activity = %{
        "type" => "EmojiReact",
        "actor" => reactor.uri,
        "object" => wrapper_uri,
        "content" => ":thumbsup:"
      }

      assert {:ok, :emoji_reacted} = LikeHandler.handle_emoji_react(activity, reactor.uri, nil)
      assert %{visibility: "public"} = Messaging.get_message_by_activitypub_id(object_id)
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

    test "uses embedded Like.object when undoing a standard Like activity" do
      liker = remote_actor_fixture("undo_liker")
      message = remote_message_fixture("undo-like-post")

      assert {:ok, _like} = Messaging.create_federated_like(message.id, liker.id)

      object = %{
        "type" => "Like",
        "id" => "https://remote.server/likes/#{System.unique_integer([:positive])}",
        "object" => message.activitypub_id
      }

      assert {:ok, :unliked} = LikeHandler.handle_undo_like(object, liker.uri)
      assert Repo.get_by(FederatedLike, message_id: message.id, remote_actor_id: liker.id) == nil
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

    test "uses embedded EmojiReact.object when undoing a standard reaction activity" do
      reactor = remote_actor_fixture("undo_reactor")
      message = remote_message_fixture("undo-reaction-post")

      assert {:ok, _reaction} =
               Elektrine.Messaging.Messages.create_federated_emoji_reaction(
                 message.id,
                 reactor.id,
                 ":blobcat:"
               )

      object = %{
        "type" => "EmojiReact",
        "id" => "https://remote.server/reactions/#{System.unique_integer([:positive])}",
        "object" => message.activitypub_id,
        "content" => ":blobcat:"
      }

      assert {:ok, :emoji_unreacted} = LikeHandler.handle_undo_emoji_react(object, reactor.uri)

      assert Repo.get_by(MessageReaction,
               message_id: message.id,
               remote_actor_id: reactor.id,
               emoji: ":blobcat:"
             ) == nil
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

    test "uses embedded Dislike.object when undoing a standard Dislike activity" do
      disliker = remote_actor_fixture("undo_disliker")
      message = remote_message_fixture("undo-dislike-post")

      assert {:ok, _dislike} = Messaging.create_federated_dislike(message.id, disliker.id)

      object = %{
        "type" => "Dislike",
        "id" => "https://remote.server/dislikes/#{System.unique_integer([:positive])}",
        "object" => message.activitypub_id
      }

      assert {:ok, :undisliked} = LikeHandler.handle_undo_dislike(object, disliker.uri)

      assert Repo.get_by(FederatedDislike, message_id: message.id, remote_actor_id: disliker.id) ==
               nil
    end
  end

  defp remote_actor_fixture(label) do
    unique_id = System.unique_integer([:positive])
    username = "#{label}#{unique_id}"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.server/users/#{username}",
      username: username,
      domain: "remote.server",
      inbox_url: "https://remote.server/users/#{username}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp remote_message_fixture(label) do
    author = remote_actor_fixture("#{label}-author")
    ap_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "#{label} content",
        visibility: "public",
        activitypub_id: ap_id,
        activitypub_url: "#{ap_id}/view",
        federated: true,
        remote_actor_id: author.id,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    message
  end
end
