defmodule Elektrine.ActivityPub.OutboxTest do
  use Elektrine.DataCase, async: true

  import Ecto.Query

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Actor, Builder, Delivery, Outbox}
  alias Elektrine.Messaging
  alias Elektrine.Social
  alias Elektrine.SocialFixtures

  # Create a mock user struct for testing builders
  defp mock_user(username \\ "testuser") do
    %Elektrine.Accounts.User{
      id: 1,
      username: username,
      activitypub_enabled: true
    }
  end

  defp mock_message(attrs) do
    defaults = %{
      id: 1,
      content: "Test post",
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      visibility: "public",
      message_type: "text",
      post_type: "post",
      extracted_hashtags: [],
      media_urls: [],
      media_metadata: %{},
      sensitive: false
    }

    struct(Elektrine.Social.Message, Map.merge(defaults, attrs))
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

  describe "Note builder" do
    test "serializes followers-only posts to the followers collection" do
      user = mock_user("followersonly")
      message = mock_message(%{visibility: "followers"})

      note = Builder.build_note(message, user)

      assert note["to"] == [
               "#{Elektrine.ActivityPub.instance_url()}/users/#{user.username}/followers"
             ]

      refute "https://www.w3.org/ns/activitystreams#Public" in note["to"]
    end
  end

  describe "community note builder" do
    test "includes attachments and ActivityPub hashtag links" do
      previous_uploads_config = Application.get_env(:elektrine, :uploads)

      on_exit(fn ->
        Application.put_env(:elektrine, :uploads, previous_uploads_config)
      end)

      Application.put_env(:elektrine, :uploads, public_url: "https://uploads.example")

      author = mock_user("communityauthor")
      community = %Elektrine.Social.Conversation{name: "fedigroup"}

      message =
        mock_message(%{
          id: 123,
          content: "Hello #fediverse",
          sender: author,
          extracted_hashtags: ["fediverse"],
          media_urls: ["/uploads/test-image.jpg"],
          media_metadata: %{"alt_texts" => %{"0" => "Preview image"}}
        })

      note = Builder.build_community_note(message, community)

      assert [%{"url" => attachment_url, "name" => "Preview image"}] = note["attachment"]
      assert String.ends_with?(attachment_url, "/uploads/test-image.jpg")

      assert Enum.any?(note["tag"], fn tag ->
               tag["type"] == "Hashtag" and
                 tag["href"] == "#{ActivityPub.instance_url()}/tags/fediverse"
             end)
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

  describe "undo federation" do
    test "uses the stored Like activity id when federating unlike" do
      user = AccountsFixtures.user_fixture()
      remote_actor = remote_actor_fixture("undo-like")
      message = remote_message_fixture(remote_actor)
      original_id = "https://example.test/activities/#{Ecto.UUID.generate()}-like"

      {:ok, _activity} =
        ActivityPub.create_activity(%{
          activity_id: original_id,
          activity_type: "Like",
          actor_uri: "#{ActivityPub.instance_url()}/users/#{user.username}",
          object_id: message.activitypub_id,
          data: %{
            "id" => original_id,
            "type" => "Like",
            "actor" => "#{ActivityPub.instance_url()}/users/#{user.username}",
            "object" => message.activitypub_id
          },
          local: true,
          internal_user_id: user.id
        })

      assert :ok = Outbox.federate_unlike(message.id, user.id)

      assert %{data: %{"object" => %{"id" => ^original_id, "type" => "Like"}}} =
               Repo.get_by!(ActivityPub.Activity,
                 internal_user_id: user.id,
                 activity_type: "Undo",
                 object_id: original_id
               )
    end

    test "uses the stored Dislike activity id when federating undo dislike" do
      user = AccountsFixtures.user_fixture()
      remote_actor = remote_actor_fixture("undo-dislike")
      message = remote_message_fixture(remote_actor)
      original_id = "https://example.test/activities/#{Ecto.UUID.generate()}-dislike"

      {:ok, _activity} =
        ActivityPub.create_activity(%{
          activity_id: original_id,
          activity_type: "Dislike",
          actor_uri: "#{ActivityPub.instance_url()}/users/#{user.username}",
          object_id: message.activitypub_id,
          data: %{
            "id" => original_id,
            "type" => "Dislike",
            "actor" => "#{ActivityPub.instance_url()}/users/#{user.username}",
            "object" => message.activitypub_id
          },
          local: true,
          internal_user_id: user.id
        })

      assert :ok = Outbox.federate_undo_dislike(message.id, user.id)

      assert %{data: %{"object" => %{"id" => ^original_id, "type" => "Dislike"}}} =
               Repo.get_by!(ActivityPub.Activity,
                 internal_user_id: user.id,
                 activity_type: "Undo",
                 object_id: original_id
               )
    end

    test "uses the stored Announce activity id when federating undo announce" do
      user = AccountsFixtures.user_fixture()
      remote_actor = remote_actor_fixture("undo-announce")
      message = remote_message_fixture(remote_actor)
      original_id = "https://example.test/activities/#{Ecto.UUID.generate()}-announce"

      {:ok, _activity} =
        ActivityPub.create_activity(%{
          activity_id: original_id,
          activity_type: "Announce",
          actor_uri: "#{ActivityPub.instance_url()}/users/#{user.username}",
          object_id: message.activitypub_id,
          data: %{
            "id" => original_id,
            "type" => "Announce",
            "actor" => "#{ActivityPub.instance_url()}/users/#{user.username}",
            "object" => message.activitypub_id,
            "to" => ["https://www.w3.org/ns/activitystreams#Public"],
            "cc" => ["#{ActivityPub.instance_url()}/users/#{user.username}/followers"]
          },
          local: true,
          internal_user_id: user.id
        })

      assert :ok = Outbox.federate_undo_announce(message.id, user.id)

      assert %{data: %{"object" => %{"id" => ^original_id, "type" => "Announce"}}} =
               Repo.get_by!(ActivityPub.Activity,
                 internal_user_id: user.id,
                 activity_type: "Undo",
                 object_id: original_id
               )
    end

    test "uses the stored EmojiReact activity id when federating undo emoji react" do
      user = AccountsFixtures.user_fixture()
      remote_actor = remote_actor_fixture("undo-emoji")
      message = remote_message_fixture(remote_actor)
      original_id = "https://example.test/activities/#{Ecto.UUID.generate()}-emoji"

      {:ok, _activity} =
        ActivityPub.create_activity(%{
          activity_id: original_id,
          activity_type: "EmojiReact",
          actor_uri: "#{ActivityPub.instance_url()}/users/#{user.username}",
          object_id: message.activitypub_id,
          data: %{
            "id" => original_id,
            "type" => "EmojiReact",
            "actor" => "#{ActivityPub.instance_url()}/users/#{user.username}",
            "object" => message.activitypub_id,
            "content" => ":blobcat:"
          },
          local: true,
          internal_user_id: user.id
        })

      assert :ok = Outbox.federate_undo_emoji_react(message.id, user.id, ":blobcat:")

      assert %{data: %{"object" => %{"id" => ^original_id, "type" => "EmojiReact"}}} =
               Repo.get_by!(ActivityPub.Activity,
                 internal_user_id: user.id,
                 activity_type: "Undo",
                 object_id: original_id
               )
    end
  end

  describe "update/delete federation" do
    test "reuses the original Create delivery inboxes for updates and deletes" do
      user = AccountsFixtures.user_fixture()
      message = local_post_fixture(user)
      create_activity = create_local_create_activity(user, message.activitypub_id)

      original_inboxes = [
        "https://followers.example/inbox",
        "https://relay.example/inbox",
        "https://community.example/inbox"
      ]

      ActivityPub.create_deliveries(create_activity.id, original_inboxes)

      assert :ok = Outbox.federate_update(message)
      assert :ok = Outbox.federate_delete(message)

      assert_delivery_inboxes("Update", message.activitypub_id, user.id, original_inboxes)
      assert_delivery_inboxes("Delete", message.activitypub_id, user.id, original_inboxes)
    end

    test "preserves followers-only audience on Update and Delete wrappers" do
      user = AccountsFixtures.user_fixture()
      message = local_post_fixture(user, visibility: "followers")
      followers_url = "#{ActivityPub.instance_url()}/users/#{user.username}/followers"

      create_activity =
        create_local_create_activity(user, message.activitypub_id,
          to: [followers_url],
          cc: []
        )

      ActivityPub.create_deliveries(create_activity.id, ["https://followers.example/inbox"])

      assert :ok = Outbox.federate_update(message)
      assert :ok = Outbox.federate_delete(message)

      assert %{data: update_data} =
               Repo.get_by!(ActivityPub.Activity,
                 internal_user_id: user.id,
                 activity_type: "Update",
                 object_id: message.activitypub_id
               )

      assert %{data: delete_data} =
               Repo.get_by!(ActivityPub.Activity,
                 internal_user_id: user.id,
                 activity_type: "Delete",
                 object_id: message.activitypub_id
               )

      assert update_data["to"] == [followers_url]
      assert Map.get(update_data, "cc", []) == []
      assert delete_data["to"] == [followers_url]
      assert Map.get(delete_data, "cc", []) == []

      refute "https://www.w3.org/ns/activitystreams#Public" in update_data["to"]
      refute "https://www.w3.org/ns/activitystreams#Public" in delete_data["to"]
    end

    test "reuses the original community Create delivery inboxes and actor for updates and deletes" do
      owner = AccountsFixtures.user_fixture()
      community = SocialFixtures.community_conversation_fixture(owner)
      {:ok, community_actor} = ActivityPub.get_or_create_community_actor(community.id)
      message = local_community_post_fixture(owner, community)

      create_activity =
        create_local_community_create_activity(message, community, community_actor)

      original_inboxes = [
        "https://community-followers.example/inbox",
        "https://relay.example/inbox",
        "https://mentioned.example/inbox"
      ]

      ActivityPub.create_deliveries(create_activity.id, original_inboxes)

      assert :ok = Outbox.federate_update(message)
      assert :ok = Outbox.federate_delete(message)

      assert_delivery_inboxes_for_actor(
        "Update",
        message.activitypub_id,
        community_actor.uri,
        original_inboxes
      )

      assert_delivery_inboxes_for_actor(
        "Delete",
        message.activitypub_id,
        community_actor.uri,
        original_inboxes
      )

      community_actor_uri = community_actor.uri

      assert %{data: %{"actor" => ^community_actor_uri}} =
               Repo.get_by!(ActivityPub.Activity,
                 actor_uri: community_actor.uri,
                 activity_type: "Update",
                 object_id: message.activitypub_id
               )

      assert %{data: %{"actor" => ^community_actor_uri}} =
               Repo.get_by!(ActivityPub.Activity,
                 actor_uri: community_actor.uri,
                 activity_type: "Delete",
                 object_id: message.activitypub_id
               )
    end
  end

  describe "community federation" do
    test "includes mentioned remote actors in local community post delivery and audience" do
      owner = AccountsFixtures.user_fixture()
      community = SocialFixtures.community_conversation_fixture(owner)
      remote_actor = remote_actor_fixture("communitymention")

      acct = "#{remote_actor.username}@#{remote_actor.domain}"
      remote_actor_uri = remote_actor.uri

      assert {:ok, ^remote_actor_uri} =
               Elektrine.AppCache.get_webfinger(acct, fn -> {:ok, remote_actor.uri} end)

      message =
        SocialFixtures.discussion_post_fixture(%{
          user: owner,
          community: community,
          content: "Hello @#{remote_actor.username}@#{remote_actor.domain}"
        })

      assert :ok = Outbox.federate_community_post(message, community)

      {:ok, community_actor} = ActivityPub.get_or_create_community_actor(community.id)

      activity =
        Repo.get_by!(ActivityPub.Activity,
          actor_uri: community_actor.uri,
          activity_type: "Create",
          object_id: ActivityPub.community_post_uri(community.name, message.id)
        )

      deliveries =
        Delivery
        |> where([d], d.activity_id == ^activity.id)
        |> select([d], d.inbox_url)
        |> Repo.all()

      assert remote_actor.inbox_url in deliveries
      assert remote_actor.uri in activity.data["cc"]
      assert remote_actor.uri in activity.data["object"]["cc"]
    end

    test "preserves mirrored remote-group routing on updates and reuses mirrored deliveries" do
      owner = AccountsFixtures.user_fixture()
      remote_group = remote_group_actor_fixture("mirrorgroup")

      community =
        owner
        |> SocialFixtures.community_conversation_fixture()
        |> Ecto.Changeset.change(
          is_federated_mirror: true,
          remote_group_actor_id: remote_group.id,
          federated_source: remote_group.uri
        )
        |> Repo.update!()

      message = SocialFixtures.discussion_post_fixture(%{user: owner, community: community})

      assert :ok = Outbox.federate_community_post(message, community)

      reloaded_message =
        Messaging.get_message(message.id)
        |> Repo.preload([:sender, :conversation])

      edited_message =
        reloaded_message
        |> Ecto.Changeset.change(content: "Edited mirrored post")
        |> Repo.update!()
        |> Repo.preload([:sender, :conversation])

      assert :ok = Outbox.federate_update(edited_message)
      assert :ok = Outbox.federate_delete(edited_message)

      base_url = ActivityPub.instance_url()

      assert %{data: update_data} =
               Repo.get_by!(ActivityPub.Activity,
                 internal_user_id: owner.id,
                 activity_type: "Update",
                 object_id: edited_message.activitypub_id
               )

      assert update_data["actor"] == "#{base_url}/users/#{owner.username}"
      assert update_data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]
      assert update_data["cc"] == [remote_group.uri]
      assert update_data["object"]["to"] == ["https://www.w3.org/ns/activitystreams#Public"]
      assert update_data["object"]["cc"] == [remote_group.uri]
      assert update_data["object"]["audience"] == remote_group.uri
      assert update_data["object"]["context"] == remote_group.uri

      assert_delivery_inboxes("Update", edited_message.activitypub_id, owner.id, [
        remote_group.inbox_url
      ])

      assert_delivery_inboxes("Delete", edited_message.activitypub_id, owner.id, [
        remote_group.inbox_url
      ])
    end
  end

  describe "poll vote federation" do
    test "publishes remote poll votes as Create activities to the remote author inbox" do
      voter = AccountsFixtures.user_fixture()
      remote_actor = remote_actor_fixture("pollauthor")
      remote_message = remote_message_fixture(remote_actor)

      {:ok, poll} = Social.create_poll(remote_message.id, "Pick one", ["Alpha", "Beta"])
      poll = Repo.preload(poll, :options)
      option = hd(poll.options)

      assert :ok =
               Outbox.federate_poll_vote(
                 poll,
                 option,
                 voter,
                 Repo.preload(remote_message, :remote_actor)
               )

      object_id =
        "#{ActivityPub.instance_url()}/users/#{voter.username}/votes/#{poll.id}/#{option.id}"

      activity =
        Repo.get_by!(ActivityPub.Activity,
          internal_user_id: voter.id,
          activity_type: "Create",
          object_id: object_id
        )

      assert activity.data["object"]["type"] == "Note"
      assert activity.data["object"]["name"] == option.option_text
      assert activity.data["object"]["inReplyTo"] == remote_message.activitypub_id
      assert activity.data["to"] == [remote_actor.uri]
      assert_delivery_inboxes("Create", object_id, voter.id, [remote_actor.inbox_url])
    end

    test "sends direct remote poll votes to the target inbox" do
      voter = AccountsFixtures.user_fixture()
      remote_actor = remote_actor_fixture("directpoll")
      poll_id = "https://remote.example/questions/#{System.unique_integer([:positive])}"

      assert :ok = Outbox.send_poll_vote(voter, poll_id, "Option A", remote_actor)

      activity =
        ActivityPub.Activity
        |> where([a], a.internal_user_id == ^voter.id and a.activity_type == "Create")
        |> order_by([a], desc: a.inserted_at, desc: a.id)
        |> limit(1)
        |> Repo.one!()

      assert activity.data["object"]["type"] == "Note"
      assert activity.data["object"]["name"] == "Option A"
      assert activity.data["object"]["inReplyTo"] == poll_id
      assert activity.data["to"] == [remote_actor.uri]

      actual_inboxes =
        Delivery
        |> where([d], d.activity_id == ^activity.id)
        |> select([d], d.inbox_url)
        |> Repo.all()

      assert actual_inboxes == [remote_actor.inbox_url]
    end
  end

  describe "report federation" do
    test "prefers the cached shared inbox when federating a report" do
      reporter = AccountsFixtures.user_fixture()

      target_actor =
        remote_actor_fixture("reported",
          metadata: %{"endpoints" => %{"sharedInbox" => "https://remote.example/inbox"}}
        )

      assert :ok =
               Outbox.federate_report(
                 reporter.id,
                 target_actor.uri,
                 ["https://remote.example/posts/spam"],
                 "Spam"
               )

      activity =
        ActivityPub.Activity
        |> where([a], a.internal_user_id == ^reporter.id and a.activity_type == "Flag")
        |> order_by([a], desc: a.inserted_at, desc: a.id)
        |> limit(1)
        |> Repo.one!()

      assert activity.data["actor"] == "#{ActivityPub.instance_url()}/users/#{reporter.username}"

      actual_inboxes =
        Delivery
        |> where([d], d.activity_id == ^activity.id)
        |> select([d], d.inbox_url)
        |> Repo.all()

      assert actual_inboxes == ["https://remote.example/inbox"]
    end

    test "preserves a non-default port when falling back to an instance inbox" do
      reporter = AccountsFixtures.user_fixture()
      target_actor_uri = "https://reports.example:8443/users/spammer"

      assert :ok = Outbox.federate_report(reporter.id, target_actor_uri, [], "Abuse")

      activity =
        ActivityPub.Activity
        |> where([a], a.internal_user_id == ^reporter.id and a.activity_type == "Flag")
        |> order_by([a], desc: a.inserted_at, desc: a.id)
        |> limit(1)
        |> Repo.one!()

      actual_inboxes =
        Delivery
        |> where([d], d.activity_id == ^activity.id)
        |> select([d], d.inbox_url)
        |> Repo.all()

      assert actual_inboxes == ["https://reports.example:8443/inbox"]
    end
  end

  defp remote_actor_fixture(label, attrs \\ []) do
    unique = System.unique_integer([:positive])
    username = "#{label}#{unique}"
    uri = "https://remote.example/users/#{username}"

    %Actor{}
    |> Actor.changeset(
      attrs
      |> Enum.into(%{
        uri: uri,
        username: username,
        domain: "remote.example",
        inbox_url: "https://remote.example/users/#{username}/inbox",
        public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----",
        last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    )
    |> Repo.insert!()
  end

  defp remote_group_actor_fixture(label) do
    remote_actor_fixture(label,
      actor_type: "Group",
      uri: "https://remote.example/c/#{label}",
      username: label,
      inbox_url: "https://remote.example/c/#{label}/inbox"
    )
  end

  defp remote_message_fixture(remote_actor) do
    unique = System.unique_integer([:positive])

    Messaging.create_federated_message(%{
      content: "Remote target #{unique}",
      visibility: "public",
      activitypub_id: "https://remote.example/objects/#{unique}",
      activitypub_url: "https://remote.example/objects/#{unique}",
      federated: true,
      remote_actor_id: remote_actor.id,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> then(fn {:ok, message} -> message end)
  end

  defp local_post_fixture(user, attrs \\ []) do
    attrs = Enum.into(attrs, %{})
    visibility = Map.get(attrs, :visibility, "public")

    message =
      SocialFixtures.post_fixture(%{
        user: user,
        visibility: visibility,
        content: "Local post #{System.unique_integer([:positive])}"
      })

    object_id = "#{ActivityPub.instance_url()}/users/#{user.username}/statuses/#{message.id}"

    message
    |> Ecto.Changeset.change(activitypub_id: object_id, activitypub_url: object_id)
    |> Repo.update!()
    |> Repo.preload([:sender, :conversation])
  end

  defp create_local_create_activity(user, object_id, opts \\ []) do
    to = Keyword.get(opts, :to, ["https://www.w3.org/ns/activitystreams#Public"])

    cc =
      Keyword.get(opts, :cc, ["#{ActivityPub.instance_url()}/users/#{user.username}/followers"])

    activity_id = "#{object_id}/activity"
    actor_uri = "#{ActivityPub.instance_url()}/users/#{user.username}"

    {:ok, activity} =
      ActivityPub.create_activity(%{
        activity_id: activity_id,
        activity_type: "Create",
        actor_uri: actor_uri,
        object_id: object_id,
        data: %{
          "id" => activity_id,
          "type" => "Create",
          "actor" => actor_uri,
          "to" => to,
          "cc" => cc,
          "object" => %{
            "id" => object_id,
            "type" => "Note",
            "to" => to,
            "cc" => cc
          }
        },
        local: true,
        internal_user_id: user.id
      })

    activity
  end

  defp local_community_post_fixture(user, community, attrs \\ []) do
    attrs = Enum.into(attrs, %{})

    message =
      SocialFixtures.discussion_post_fixture(%{
        user: user,
        community: community,
        content: Map.get(attrs, :content, "Community post #{System.unique_integer([:positive])}")
      })

    object_id = ActivityPub.community_post_uri(community.name, message.id)

    message
    |> Ecto.Changeset.change(
      activitypub_id: object_id,
      activitypub_url: ActivityPub.community_post_web_url(community.name, message.id)
    )
    |> Repo.update!()
    |> Repo.preload([:sender, :conversation])
  end

  defp create_local_community_create_activity(message, community, community_actor) do
    activity_data =
      message
      |> Builder.build_community_object(community)
      |> then(&Builder.build_community_create_activity(message, community, &1))

    {:ok, activity} =
      ActivityPub.create_activity(%{
        activity_id: activity_data["id"],
        activity_type: "Create",
        actor_uri: community_actor.uri,
        object_id: message.activitypub_id,
        data: activity_data,
        local: true,
        internal_user_id: nil
      })

    activity
  end

  defp assert_delivery_inboxes(activity_type, object_id, user_id, expected_inboxes) do
    activity =
      Repo.get_by!(ActivityPub.Activity,
        internal_user_id: user_id,
        activity_type: activity_type,
        object_id: object_id
      )

    actual_inboxes =
      Delivery
      |> where([d], d.activity_id == ^activity.id)
      |> select([d], d.inbox_url)
      |> Repo.all()
      |> Enum.sort()

    assert actual_inboxes == Enum.sort(expected_inboxes)
  end

  defp assert_delivery_inboxes_for_actor(activity_type, object_id, actor_uri, expected_inboxes) do
    activity =
      Repo.get_by!(ActivityPub.Activity,
        actor_uri: actor_uri,
        activity_type: activity_type,
        object_id: object_id
      )

    actual_inboxes =
      Delivery
      |> where([d], d.activity_id == ^activity.id)
      |> select([d], d.inbox_url)
      |> Repo.all()
      |> Enum.sort()

    assert actual_inboxes == Enum.sort(expected_inboxes)
  end
end
