defmodule Elektrine.ActivityPub.Handlers.UpdateHandlerTest do
  use Elektrine.DataCase, async: true

  if not Code.ensure_loaded?(Elektrine.Social.Hashtag) do
    @moduletag skip: "requires :elektrine_social"
  end

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.UpdateHandler
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Message
  alias Elektrine.Social.{Poll, PostHashtag}

  test "matches a federated post by activitypub URL variant" do
    author = remote_actor_fixture("author")
    canonical_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"
    object_url = "#{canonical_id}/update"

    assert {:ok, message} =
             Messaging.create_federated_message(%{
               content: "Original content",
               visibility: "public",
               activitypub_id: canonical_id,
               activitypub_url: object_url,
               federated: true,
               remote_actor_id: author.id,
               inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    activity = %{
      "type" => "Update",
      "actor" => author.uri,
      "object" => %{
        "id" => object_url,
        "type" => "Note",
        "content" => "<p>Updated content</p>"
      }
    }

    assert {:ok, :updated} = UpdateHandler.handle(activity, author.uri, nil)
    assert Repo.get!(Message, message.id).content == "Updated content"
  end

  test "returns a retryable error when a URI-form object fetch fails" do
    unique_id = System.unique_integer([:positive])

    activity = %{
      "type" => "Update",
      "actor" => "https://remote.server/users/updater#{unique_id}",
      "object" => "http://127.0.0.1/updates/#{unique_id}"
    }

    assert {:error, :update_object_fetch_failed} =
             UpdateHandler.handle(activity, activity["actor"], nil)
  end

  test "returns a retryable error when a Person update cannot refresh the actor" do
    unique_id = System.unique_integer([:positive])
    actor_uri = "http://127.0.0.1/actors/person-update-#{unique_id}"

    activity = %{
      "type" => "Update",
      "actor" => actor_uri,
      "object" => %{
        "id" => actor_uri,
        "type" => "Person"
      }
    }

    assert {:error, :update_actor_fetch_failed} =
             UpdateHandler.handle(activity, actor_uri, nil)
  end

  test "returns a retryable error when a Group update cannot refresh the actor" do
    unique_id = System.unique_integer([:positive])
    actor_uri = "http://127.0.0.1/groups/update-#{unique_id}"

    activity = %{
      "type" => "Update",
      "actor" => actor_uri,
      "object" => %{
        "id" => actor_uri,
        "type" => "Group"
      }
    }

    assert {:error, :update_actor_fetch_failed} =
             UpdateHandler.handle(activity, actor_uri, nil)
  end

  test "rejects Group updates whose object id does not match the verified actor" do
    unique_id = System.unique_integer([:positive])
    actor_uri = "https://remote.server/groups/#{unique_id}"
    other_group_uri = "https://other.example/groups/#{unique_id}"

    activity = %{
      "type" => "Update",
      "actor" => actor_uri,
      "object" => %{
        "id" => other_group_uri,
        "type" => "Group"
      }
    }

    assert {:ok, :unauthorized} = UpdateHandler.handle(activity, actor_uri, nil)
  end

  test "imports unknown public Note objects from Update activities" do
    author = remote_actor_fixture("updatedauthor")
    object_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"

    activity = %{
      "type" => "Update",
      "actor" => author.uri,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "id" => object_id,
        "type" => "Note",
        "content" => "<p>Updated before create</p>",
        "attributedTo" => author.uri,
        "to" => [],
        "cc" => []
      }
    }

    assert {:ok, :created_from_update} = UpdateHandler.handle(activity, author.uri, nil)

    assert %{content: "Updated before create", visibility: "public"} =
             Messaging.get_message_by_activitypub_id(object_id)
  end

  test "refreshes title, warnings, media, hashtags, and engagement data for remote notes" do
    author = remote_actor_fixture("richupdate")
    object_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"

    assert {:ok, message} =
             Messaging.create_federated_message(%{
               content: "Original content",
               title: "Original title",
               visibility: "public",
               activitypub_id: object_id,
               activitypub_url: object_id,
               federated: true,
               remote_actor_id: author.id,
               media_urls: ["https://remote.server/old.png"],
               media_metadata: %{
                 "alt_texts" => %{"0" => "Old alt"},
                 "boosted_by" => "keep-me",
                 "community_actor_uri" => "https://remote.server/c/old"
               },
               extracted_hashtags: ["oldtag"],
               like_count: 1,
               reply_count: 2,
               share_count: 3,
               inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    old_hashtag = Social.get_or_create_hashtag("oldtag")
    Social.increment_hashtag_usage(old_hashtag.id)

    %PostHashtag{}
    |> PostHashtag.changeset(%{message_id: message.id, hashtag_id: old_hashtag.id})
    |> Repo.insert!()

    activity = %{
      "type" => "Update",
      "actor" => author.uri,
      "object" => %{
        "id" => object_id,
        "type" => "Note",
        "content" => "<p>Updated content with #newtag</p>",
        "name" => "<p>Updated title</p>",
        "summary" => "Updated CW",
        "sensitive" => true,
        "url" => "#{object_id}/rendered",
        "likes" => %{"totalItems" => 7},
        "replies" => %{"totalItems" => 8},
        "shares" => %{"totalItems" => 9},
        "attachment" => [
          %{
            "type" => "Document",
            "mediaType" => "image/png",
            "url" => "https://remote.server/new.png",
            "name" => "New alt"
          }
        ],
        "tag" => [
          %{"type" => "Hashtag", "name" => "#newtag"}
        ],
        "attributedTo" => author.uri,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    assert {:ok, :updated} = UpdateHandler.handle(activity, author.uri, nil)

    updated_message =
      Repo.get!(Message, message.id)
      |> Repo.preload(:hashtags)

    assert updated_message.content == "Updated content with #newtag"
    assert updated_message.title == "Updated title"
    assert updated_message.content_warning == "Updated CW"
    assert updated_message.sensitive == true
    assert updated_message.media_urls == ["https://remote.server/new.png"]
    assert updated_message.activitypub_url == "#{object_id}/rendered"
    assert updated_message.like_count == 7
    assert updated_message.reply_count == 8
    assert updated_message.share_count == 9
    assert updated_message.edited_at
    assert updated_message.media_metadata["alt_texts"] == %{"0" => "New alt"}
    assert updated_message.media_metadata["boosted_by"] == "keep-me"
    refute Map.has_key?(updated_message.media_metadata, "community_actor_uri")
    assert Enum.map(updated_message.hashtags, & &1.normalized_name) == ["newtag"]

    assert Social.get_hashtag_by_normalized_name("oldtag").use_count == 0
    assert Social.get_hashtag_by_normalized_name("newtag").use_count == 1
  end

  test "refreshes poll question and options for remote Question updates" do
    author = remote_actor_fixture("pollupdate")
    object_id = "https://remote.server/questions/#{System.unique_integer([:positive])}"

    assert {:ok, message} =
             Messaging.create_federated_message(%{
               content: "Original poll body",
               visibility: "public",
               post_type: "poll",
               activitypub_id: object_id,
               activitypub_url: object_id,
               federated: true,
               remote_actor_id: author.id,
               inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    poll =
      %Poll{}
      |> Poll.changeset(%{
        message_id: message.id,
        question: "Old question",
        total_votes: 1,
        voters_count: 1,
        allow_multiple: false
      })
      |> Repo.insert!()

    Enum.each(["Old one", "Old two"], fn option_text ->
      %Elektrine.Social.PollOption{}
      |> Elektrine.Social.PollOption.changeset(%{
        poll_id: poll.id,
        option_text: option_text,
        vote_count: 1
      })
      |> Repo.insert!()
    end)

    activity = %{
      "type" => "Update",
      "actor" => author.uri,
      "object" => %{
        "id" => object_id,
        "type" => "Question",
        "name" => "<p>New question</p>",
        "content" => "",
        "summary" => "Poll CW",
        "sensitive" => true,
        "attributedTo" => author.uri,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "oneOf" => [
          %{"name" => "First", "replies" => %{"totalItems" => 4}},
          %{"name" => "Second", "replies" => %{"totalItems" => 5}}
        ]
      }
    }

    assert {:ok, :updated} = UpdateHandler.handle(activity, author.uri, nil)

    reloaded_poll =
      Repo.get_by!(Poll, message_id: message.id)
      |> Repo.preload(:options)

    updated_message = Repo.get!(Message, message.id)

    assert reloaded_poll.question == "New question"
    assert reloaded_poll.total_votes == 9
    assert reloaded_poll.voters_count == 9

    assert reloaded_poll.options
           |> Enum.sort_by(& &1.position)
           |> Enum.map(&{&1.option_text, &1.vote_count}) == [
             {"First", 4},
             {"Second", 5}
           ]

    assert updated_message.content_warning == "Poll CW"
    assert updated_message.sensitive == true
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
end
