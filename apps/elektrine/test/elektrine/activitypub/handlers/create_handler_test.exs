defmodule Elektrine.ActivityPub.Handlers.CreateHandlerTest do
  use Elektrine.DataCase, async: true

  if not Code.ensure_loaded?(Elektrine.Social.Hashtag) do
    @moduletag skip: "requires :elektrine_social"
  end

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.CreateHandler
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Poll
  alias Elektrine.SocialFixtures

  describe "create_note/2 community detection" do
    test "stores community_actor_uri from audience field" do
      author = remote_actor_fixture("alice")
      community_uri = "https://lemmy.world/c/elixir"

      object =
        note_object(author.uri, %{
          "id" => "https://lemmy.world/post/#{System.unique_integer([:positive])}",
          "audience" => community_uri
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert get_in(message.media_metadata || %{}, ["community_actor_uri"]) == community_uri
    end

    test "stores community_actor_uri from to/cc fields" do
      author = remote_actor_fixture("bob")
      community_uri = "https://programming.dev/c/elixir"

      object =
        note_object(author.uri, %{
          "id" => "https://programming.dev/post/#{System.unique_integer([:positive])}",
          "to" => [
            "https://www.w3.org/ns/activitystreams#Public",
            "https://mastodon.social/users/someone"
          ],
          "cc" => [community_uri]
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert get_in(message.media_metadata || %{}, ["community_actor_uri"]) == community_uri
    end

    test "stores community_actor_uri from target field" do
      author = remote_actor_fixture("target")
      community_uri = "https://lemmy.ml/c/federation"

      object =
        note_object(author.uri, %{
          "id" => "https://lemmy.ml/post/#{System.unique_integer([:positive])}",
          "target" => community_uri,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => []
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert get_in(message.media_metadata || %{}, ["community_actor_uri"]) == community_uri
    end

    test "falls back to inReplyTo parent community metadata when audience fields are missing" do
      parent_author = remote_actor_fixture("parent")
      author = remote_actor_fixture("reply")
      community_uri = "https://lemmy.world/c/rust"
      parent_ap_id = "https://lemmy.world/post/#{System.unique_integer([:positive])}"

      assert {:ok, _parent_message} =
               Messaging.create_federated_message(%{
                 content: "Parent post",
                 visibility: "public",
                 activitypub_id: parent_ap_id,
                 activitypub_url: parent_ap_id,
                 federated: true,
                 remote_actor_id: parent_author.id,
                 media_metadata: %{"community_actor_uri" => community_uri},
                 inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
               })

      object =
        note_object(author.uri, %{
          "id" => "https://mastodon.social/notes/#{System.unique_integer([:positive])}",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "inReplyTo" => parent_ap_id
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert get_in(message.media_metadata || %{}, ["community_actor_uri"]) == community_uri
    end

    test "stores a sanitized title from object name" do
      author = remote_actor_fixture("titled")

      object =
        note_object(author.uri, %{
          "id" => "https://lemmy.world/post/#{System.unique_integer([:positive])}",
          "content" => "",
          "name" =>
            ~s(<h1 class="font-bold text-xl mb-3">Even the DNC base is controlled opposition</h1>)
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert message.title == "Even the DNC base is controlled opposition"
    end

    test "stores immediate vote totals from lemmy style objects" do
      author = remote_actor_fixture("scored")

      object =
        note_object(author.uri, %{
          "id" => "https://lemmy.world/post/#{System.unique_integer([:positive])}",
          "upvotes" => 12,
          "downvotes" => 2,
          "score" => 10
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert message.upvotes == 12
      assert message.downvotes == 2
      assert message.score == 10
    end

    test "treats markup-only object name as no title" do
      author = remote_actor_fixture("titleempty")

      object =
        note_object(author.uri, %{
          "id" => "https://lemmy.world/post/#{System.unique_integer([:positive])}",
          "content" => "",
          "name" => "<h1 class=\"font-bold\"></h1>"
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert is_nil(message.title)
    end
  end

  describe "create_note/3 community fallback" do
    test "uses fallback_community_uri when object fields are incomplete" do
      author = remote_actor_fixture("carol")
      fallback_community_uri = "https://lemmy.ml/c/technology"

      object =
        note_object(author.uri, %{
          "id" => "https://lemmy.ml/post/#{System.unique_integer([:positive])}",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => []
        })

      assert {:ok, message} =
               CreateHandler.create_note(object, author.uri,
                 fallback_community_uri: fallback_community_uri
               )

      assert get_in(message.media_metadata || %{}, ["community_actor_uri"]) ==
               fallback_community_uri
    end
  end

  describe "handle/3 poll vote deduplication" do
    test "does not double count repeated remote Answer deliveries" do
      remote_actor = remote_actor_fixture("pollvoter")
      post = SocialFixtures.post_fixture()
      poll_post_uri = "#{ActivityPub.instance_url()}/posts/#{post.id}"

      assert {:ok, poll} = Social.create_poll(post.id, "Choose one", ["One", "Two"])

      activity = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "actor" => remote_actor.uri,
        "object" => %{
          "id" => "https://remote.example/answers/#{System.unique_integer([:positive])}",
          "type" => "Answer",
          "name" => "One",
          "inReplyTo" => poll_post_uri,
          "attributedTo" => remote_actor.uri
        }
      }

      assert {:ok, :poll_vote_recorded} = CreateHandler.handle(activity, remote_actor.uri, nil)

      reloaded_poll = Repo.get!(Poll, poll.id) |> Repo.preload(:options)
      selected_option = Enum.find(reloaded_poll.options, &(&1.option_text == "One"))

      assert reloaded_poll.total_votes == 1
      assert reloaded_poll.voters_count == 1
      assert selected_option.vote_count == 1

      assert {:ok, :already_voted} = CreateHandler.handle(activity, remote_actor.uri, nil)

      deduped_poll = Repo.get!(Poll, poll.id) |> Repo.preload(:options)
      deduped_option = Enum.find(deduped_poll.options, &(&1.option_text == "One"))

      assert deduped_poll.total_votes == 1
      assert deduped_poll.voters_count == 1
      assert deduped_option.vote_count == 1
    end
  end

  describe "handle/3 actor verification" do
    test "rejects Create when attributedTo does not match the verified actor" do
      signer = remote_actor_fixture("signer")
      claimed_author = remote_actor_fixture("claimed")

      object =
        note_object(claimed_author.uri, %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}"
        })

      activity = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => signer.uri,
        "object" => object
      }

      assert {:ok, :unauthorized} = CreateHandler.handle(activity, signer.uri, nil)
      assert is_nil(Messaging.get_message_by_activitypub_id(object["id"]))
    end

    test "rejects direct create_note calls when attributedTo does not match the actor" do
      signer = remote_actor_fixture("directsigner")
      claimed_author = remote_actor_fixture("directclaimed")

      object =
        note_object(claimed_author.uri, %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}"
        })

      assert {:error, :actor_mismatch} = CreateHandler.create_note(object, signer.uri)
      assert is_nil(Messaging.get_message_by_activitypub_id(object["id"]))
    end

    test "returns create_object_fetch_failed for Create activities with unfetchable object URIs" do
      author = remote_actor_fixture("uriobject")

      activity = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => author.uri,
        "object" => "http://127.0.0.1/objects/#{System.unique_integer([:positive])}"
      }

      assert {:error, :create_object_fetch_failed} =
               CreateHandler.handle(activity, author.uri, nil)
    end

    test "inherits public visibility from the outer Create activity" do
      author = remote_actor_fixture("outervisibility")

      object =
        note_object(author.uri, %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "to" => [],
          "cc" => []
        })

      activity = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => author.uri,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "object" => object
      }

      assert {:ok, message} = CreateHandler.handle(activity, author.uri, nil)
      assert message.visibility == "public"
    end
  end

  describe "federated content persistence" do
    test "persists content warnings and sensitive flags for remote notes" do
      author = remote_actor_fixture("sensitive")

      object =
        note_object(author.uri, %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "content" => "<p>Spoiler post</p>",
          "summary" => "Spoiler warning",
          "sensitive" => true
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert message.content == "Spoiler post"
      assert message.content_warning == "Spoiler warning"
      assert message.sensitive == true
    end

    test "uses Question name as the poll question when content is blank" do
      author = remote_actor_fixture("questionname")

      object = %{
        "type" => "Question",
        "id" => "https://remote.example/questions/#{System.unique_integer([:positive])}",
        "attributedTo" => author.uri,
        "name" => "<p>Pick a lane</p>",
        "content" => "",
        "published" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "oneOf" => [
          %{"name" => "One"},
          %{"name" => "Two"}
        ]
      }

      assert {:ok, message} = CreateHandler.create_question(object, author.uri)

      poll =
        Repo.get_by!(Poll, message_id: message.id)
        |> Repo.preload(:options)

      assert poll.question == "Pick a lane"
      assert Enum.map(poll.options, & &1.option_text) == ["One", "Two"]
    end
  end

  describe "create_note/2 mention normalization" do
    test "expands tagged short plain-text mentions into full handles" do
      _local_user = AccountsFixtures.user_fixture(%{username: "maxfield"})
      author = remote_actor_fixture("mentioner")
      local_actor_href = "#{ActivityPub.instance_url()}/users/maxfield"

      object =
        note_object(author.uri, %{
          "content" => "<p>Hello @maxfield</p>",
          "tag" => [
            %{
              "type" => "Mention",
              "href" => local_actor_href,
              "name" => "@maxfield"
            }
          ]
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert message.content == "Hello @maxfield@#{ActivityPub.instance_domain()}"
    end

    test "expands tagged short mention anchors into full handles" do
      _local_user = AccountsFixtures.user_fixture(%{username: "maxfield"})
      author = remote_actor_fixture("anchoredmention")
      local_actor_href = "#{ActivityPub.instance_url()}/users/maxfield"

      object =
        note_object(author.uri, %{
          "content" =>
            ~s(<p>Hello <span class="h-card"><a href="#{local_actor_href}" class="u-url mention">@<span>maxfield</span></a></span></p>),
          "tag" => [
            %{
              "type" => "Mention",
              "href" => local_actor_href,
              "name" => "@maxfield"
            }
          ]
        })

      assert {:ok, message} = CreateHandler.create_note(object, author.uri)
      assert message.content == "Hello @maxfield@#{ActivityPub.instance_domain()}"
    end
  end

  defp note_object(author_uri, overrides) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    defaults = %{
      "type" => "Note",
      "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
      "attributedTo" => author_uri,
      "content" => "Hello from federation",
      "published" => now,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => []
    }

    Map.merge(defaults, overrides)
  end

  defp remote_actor_fixture(label) do
    unique = System.unique_integer([:positive])
    username = "#{label}#{unique}"
    uri = "https://remote.example/users/#{username}"

    %Actor{}
    |> Actor.changeset(%{
      uri: uri,
      username: username,
      domain: "remote.example",
      inbox_url: "https://remote.example/users/#{username}/inbox",
      public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
