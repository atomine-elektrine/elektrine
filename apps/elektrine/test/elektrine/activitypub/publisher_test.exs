defmodule Elektrine.ActivityPub.PublisherTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Publisher
  alias Elektrine.Profiles

  describe "get_follower_inboxes/1" do
    test "collapses to a shared inbox only when every actor on a domain advertises it" do
      user = AccountsFixtures.user_fixture()
      shared_inbox = "https://fed.example/inbox"

      actor_one =
        remote_actor_fixture(%{
          uri: "https://fed.example/users/alice",
          username: "alice",
          inbox_url: "https://fed.example/users/alice/inbox",
          metadata: %{"endpoints" => %{"sharedInbox" => shared_inbox}}
        })

      actor_two =
        remote_actor_fixture(%{
          uri: "https://fed.example/users/bob",
          username: "bob",
          inbox_url: "https://fed.example/users/bob/inbox",
          metadata: %{"endpoints" => %{"sharedInbox" => shared_inbox}}
        })

      assert {:ok, _} = Profiles.create_remote_follow(actor_one.id, user.id)
      assert {:ok, _} = Profiles.create_remote_follow(actor_two.id, user.id)

      assert Publisher.get_follower_inboxes(user.id) == [shared_inbox]
    end

    test "keeps individual inboxes when shared inbox support is inconsistent" do
      user = AccountsFixtures.user_fixture()

      actor_one =
        remote_actor_fixture(%{
          uri: "https://fed.example/users/carol",
          username: "carol",
          inbox_url: "https://fed.example/users/carol/inbox",
          metadata: %{"endpoints" => %{"sharedInbox" => "https://fed.example/inbox"}}
        })

      actor_two =
        remote_actor_fixture(%{
          uri: "https://fed.example/users/dave",
          username: "dave",
          inbox_url: "https://fed.example/users/dave/inbox"
        })

      assert {:ok, _} = Profiles.create_remote_follow(actor_one.id, user.id)
      assert {:ok, _} = Profiles.create_remote_follow(actor_two.id, user.id)

      assert Enum.sort(Publisher.get_follower_inboxes(user.id)) ==
               Enum.sort([actor_one.inbox_url, actor_two.inbox_url])
    end
  end

  describe "deliver/4" do
    test "rejects unsafe inbox URLs before sending a request" do
      user = AccountsFixtures.user_fixture()

      assert {:error, :unsafe_inbox_url} =
               Publisher.deliver(
                 %{"id" => "https://local.test/activities/1", "type" => "Follow"},
                 user,
                 "http://127.0.0.1/inbox"
               )
    end
  end

  defp remote_actor_fixture(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      uri: "https://remote#{unique}.example/users/test#{unique}",
      username: "test#{unique}",
      domain: "fed.example",
      inbox_url: "https://fed.example/users/test#{unique}/inbox",
      public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: %{}
    }

    %Actor{}
    |> Actor.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
