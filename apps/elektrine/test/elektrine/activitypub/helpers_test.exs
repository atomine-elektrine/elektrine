defmodule Elektrine.ActivityPub.HelpersTest do
  use Elektrine.DataCase, async: true

  if not Code.ensure_loaded?(Elektrine.Social.Hashtag) do
    @moduletag skip: "requires :elektrine_social"
  end

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Helpers
  alias Elektrine.Messaging
  alias Elektrine.Repo

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

  describe "get_or_store_remote_post/1 and /2" do
    test "returns cached message for equivalent ActivityPub ref variants" do
      unique = System.unique_integer([:positive])
      base_post_id = "https://127.0.0.1:1/post/#{unique}"
      actor_uri = "https://127.0.0.1:1/u/test#{unique}"

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "test#{unique}",
          domain: "127.0.0.1",
          inbox_url: "https://127.0.0.1:1/inbox/#{unique}",
          public_key: "test-key-#{unique}"
        })
        |> Repo.insert!()

      {:ok, message} =
        Messaging.create_federated_message(%{
          content: "cached remote post",
          visibility: "public",
          activitypub_id: base_post_id,
          activitypub_url: base_post_id,
          federated: true,
          remote_actor_id: remote_actor.id
        })

      assert {:ok, cached_via_slash} = Helpers.get_or_store_remote_post("#{base_post_id}/")
      assert cached_via_slash.id == message.id

      assert {:ok, cached_via_query} =
               Helpers.get_or_store_remote_post("#{base_post_id}?view=compact#top", actor_uri)

      assert cached_via_query.id == message.id
    end
  end
end
