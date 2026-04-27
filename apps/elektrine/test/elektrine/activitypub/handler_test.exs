defmodule Elektrine.ActivityPub.HandlerTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handler
  alias Elektrine.ActivityPub.Instance
  alias Elektrine.Repo
  alias Elektrine.Social.MessageReaction
  alias Elektrine.SocialFixtures

  describe "process_activity_async/3" do
    test "rejects blocked instances before routing" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "blocked-async.example.com", blocked: true})
        |> Repo.insert()

      activity = %{
        "id" =>
          "https://blocked-async.example.com/activities/#{System.unique_integer([:positive])}",
        "type" => "CustomType",
        "actor" => "https://blocked-async.example.com/users/test",
        "object" => %{"type" => "Note", "content" => "test"}
      }

      assert {:ok, :blocked} =
               Handler.process_activity_async(
                 activity,
                 "https://blocked-async.example.com/users/test",
                 nil
               )
    end

    test "resolves shared inbox follow targets before applying per-user blocks" do
      user = AccountsFixtures.user_fixture(%{username: "sharedinboxblocked"})
      actor_uri = "https://remote.example/users/blocked"

      assert {:ok, _block} = ActivityPub.block_for_user(user.id, actor_uri)

      activity = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => actor_uri,
        "object" => "#{ActivityPub.instance_url()}/users/#{user.username}"
      }

      assert {:ok, :blocked} = Handler.process_activity_async(activity, actor_uri, nil)
    end

    test "does not infer a single blocked target user from mentions on public activities" do
      user = AccountsFixtures.user_fixture(%{username: "publicmentionblocked"})
      actor_uri = "https://remote.example/users/public-mention-blocked"

      assert {:ok, _block} = ActivityPub.block_for_user(user.id, actor_uri)

      activity = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "CustomType",
        "actor" => actor_uri,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => %{
          "id" => "https://remote.example/objects/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "Hello @#{user.username}",
          "tag" => [
            %{
              "type" => "Mention",
              "href" => "#{ActivityPub.instance_url()}/users/#{user.username}",
              "name" => "@#{user.username}"
            }
          ],
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => []
        }
      }

      assert {:ok, :unhandled} = Handler.process_activity_async(activity, actor_uri, nil)
    end

    test "resolves URI-form Undo activities from stored local state before fetching" do
      user = AccountsFixtures.user_fixture()
      message = SocialFixtures.post_fixture(%{user: user, visibility: "public"})
      remote_actor = remote_actor_fixture("undo_liker")
      like_id = "https://remote.example/likes/#{System.unique_integer([:positive])}"

      like_activity = %{
        "id" => like_id,
        "type" => "Like",
        "actor" => remote_actor.uri,
        "object" => "#{ActivityPub.instance_url()}/posts/#{message.id}"
      }

      undo_activity = %{
        "id" => "https://remote.example/undo/#{System.unique_integer([:positive])}",
        "type" => "Undo",
        "actor" => remote_actor.uri,
        "object" => like_id
      }

      assert {:ok, :liked} = Handler.process_activity_async(like_activity, remote_actor.uri, nil)

      assert {:ok, :unliked} =
               Handler.process_activity_async(undo_activity, remote_actor.uri, nil)
    end

    test "returns an error when a URI-form Undo object cannot be fetched" do
      actor_uri = "https://remote.example/users/undo-fetch-failure"

      activity = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Undo",
        "actor" => actor_uri,
        "object" => "http://127.0.0.1/undo/#{System.unique_integer([:positive])}"
      }

      assert {:error, :undo_activity_fetch_failed} =
               Handler.process_activity_async(activity, actor_uri, nil)
    end

    test "resolves URI-form Undo EmojiReact activities from stored local state before fetching" do
      user = AccountsFixtures.user_fixture()
      message = SocialFixtures.post_fixture(%{user: user, visibility: "public"})
      remote_actor = remote_actor_fixture("undo_reactor")
      reaction_id = "https://remote.example/reactions/#{System.unique_integer([:positive])}"
      object_id = "#{ActivityPub.instance_url()}/posts/#{message.id}"

      assert {:ok, _reaction} =
               Elektrine.Social.Messages.create_federated_emoji_reaction(
                 message.id,
                 remote_actor.id,
                 ":blobcat:"
               )

      assert {:ok, _activity} =
               ActivityPub.create_activity(%{
                 activity_id: reaction_id,
                 activity_type: "EmojiReact",
                 actor_uri: remote_actor.uri,
                 object_id: object_id,
                 data: %{
                   "id" => reaction_id,
                   "type" => "EmojiReact",
                   "actor" => remote_actor.uri,
                   "object" => object_id,
                   "content" => ":blobcat:"
                 },
                 local: false,
                 processed: true
               })

      undo_activity = %{
        "id" => "https://remote.example/undo/#{System.unique_integer([:positive])}",
        "type" => "Undo",
        "actor" => remote_actor.uri,
        "object" => reaction_id
      }

      assert {:ok, :emoji_unreacted} =
               Handler.process_activity_async(undo_activity, remote_actor.uri, nil)

      assert Repo.get_by(MessageReaction,
               message_id: message.id,
               remote_actor_id: remote_actor.id,
               emoji: ":blobcat:"
             ) == nil
    end

    test "rejects structurally invalid activities before routing" do
      actor_uri = "https://remote.example/users/invalid-follow"

      activity = %{
        "type" => "Follow",
        "actor" => actor_uri
      }

      assert {:ok, :invalid} = Handler.process_activity_async(activity, actor_uri, nil)
    end
  end

  describe "extract_local_mentions/1" do
    test "extracts username from example.net mention" do
      local_domain = Elektrine.Domains.instance_domain()

      object = %{
        "tag" => [
          %{
            "type" => "Mention",
            "href" => "https://#{local_domain}/users/testuser",
            "name" => "@testuser@#{local_domain}"
          }
        ]
      }

      result = Handler.extract_local_mentions(object)
      assert result == ["testuser"]
    end

    test "extracts username from example.com mention" do
      local_domain = Elektrine.Domains.primary_email_domain()

      object = %{
        "tag" => [
          %{
            "type" => "Mention",
            "href" => "https://#{local_domain}/users/testuser",
            "name" => "@testuser@#{local_domain}"
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
      domains =
        Elektrine.Domains.activitypub_domains()
        |> Enum.take(2)

      [first_domain | rest] = domains
      second_domain = List.first(rest) || first_domain

      object = %{
        "tag" => [
          %{
            "type" => "Mention",
            "href" => "https://#{first_domain}/users/alice",
            "name" => "@alice@#{first_domain}"
          },
          %{
            "type" => "Mention",
            "href" => "https://#{second_domain}/users/bob",
            "name" => "@bob@#{second_domain}"
          },
          %{
            "type" => "Mention",
            "href" => "https://mastodon.social/users/charlie",
            "name" => "@charlie@mastodon.social"
          },
          %{
            "type" => "Hashtag",
            "href" => "https://example.net/tags/test",
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

  defp remote_actor_fixture(label) do
    unique_id = System.unique_integer([:positive])
    username = "#{label}#{unique_id}"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.example/users/#{username}",
      username: username,
      domain: "remote.example",
      inbox_url: "https://remote.example/users/#{username}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
