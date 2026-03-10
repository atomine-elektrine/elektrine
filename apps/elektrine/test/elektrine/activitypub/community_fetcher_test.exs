defmodule Elektrine.ActivityPub.CommunityFetcherTest do
  use ExUnit.Case, async: false

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.CommunityFetcher
  alias Elektrine.Messaging.Message

  defmodule ActivityPubStub do
    def fetch_remote_user_timeline(remote_actor_id, opts) do
      send(self(), {:fetch_remote_user_timeline, remote_actor_id, opts})
      Process.get(:community_fetcher_timeline_result, {:ok, []})
    end
  end

  defmodule HandlerStub do
    def store_remote_post(post_object, actor_uri) do
      send(self(), {:store_remote_post, post_object, actor_uri})
      Process.get(:community_fetcher_store_result, {:ok, :unhandled})
    end
  end

  defmodule MessagingStub do
    def get_message_by_activitypub_id(activitypub_id) do
      send(self(), {:get_message_by_activitypub_id, activitypub_id})
      Process.get(:community_fetcher_existing_message)
    end

    def update_message(message, attrs) do
      send(self(), {:update_message, message, attrs})
      {:ok, message}
    end
  end

  setup do
    previous_config = Application.get_env(:elektrine, :community_fetcher)

    on_exit(fn ->
      if previous_config == nil do
        Application.delete_env(:elektrine, :community_fetcher)
      else
        Application.put_env(:elektrine, :community_fetcher, previous_config)
      end

      Process.delete(:community_fetcher_timeline_result)
      Process.delete(:community_fetcher_store_result)
      Process.delete(:community_fetcher_existing_message)
    end)

    community_actor = %Actor{
      id: 42,
      uri: "https://remote.example/c/test",
      username: "test",
      domain: "remote.example"
    }

    Application.put_env(:elektrine, :community_fetcher,
      followed_communities: fn -> [community_actor] end,
      activitypub: ActivityPubStub,
      handler: HandlerStub,
      messaging: MessagingStub,
      sleep: fn _ -> :ok end
    )

    {:ok, community_actor: community_actor}
  end

  test "uses the post author URI when storing community timeline posts", %{
    community_actor: community_actor
  } do
    post_object = %{
      "id" => "https://remote.example/post/1",
      "attributedTo" => "https://remote.example/users/alice"
    }

    stored_message = %Message{id: 1001, media_metadata: %{"existing" => true}}

    Process.put(:community_fetcher_timeline_result, {:ok, [post_object]})
    Process.put(:community_fetcher_store_result, {:ok, stored_message})

    assert {:noreply, %{}} = CommunityFetcher.handle_info(:fetch_community_posts, %{})

    assert_received {:store_remote_post, ^post_object, "https://remote.example/users/alice"}

    assert_received {:update_message, ^stored_message, attrs}
    assert attrs.media_metadata["existing"] == true
    assert attrs.media_metadata["community_actor_uri"] == community_actor.uri
  end

  test "skips non-message ok results without trying to update message metadata" do
    post_object = %{
      "id" => "https://remote.example/post/2",
      "attributedTo" => "https://remote.example/users/bob"
    }

    Process.put(:community_fetcher_timeline_result, {:ok, [post_object]})
    Process.put(:community_fetcher_store_result, {:ok, :unauthorized})

    assert {:noreply, %{}} = CommunityFetcher.handle_info(:fetch_community_posts, %{})

    assert_received {:store_remote_post, ^post_object, "https://remote.example/users/bob"}
    refute_received {:update_message, _, _}
  end
end
