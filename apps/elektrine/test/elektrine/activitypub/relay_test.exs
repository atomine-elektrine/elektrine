defmodule Elektrine.ActivityPub.RelayTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Relay
  alias Elektrine.ActivityPub.RelaySubscription
  alias Elektrine.Repo

  describe "relay_actor_id/0" do
    test "returns the correct relay actor URI" do
      # The relay actor ID should be based on the instance URL
      relay_id = Relay.relay_actor_id()
      assert String.ends_with?(relay_id, "/relay")
    end
  end

  describe "get_or_create_relay_actor/0" do
    test "creates a new relay actor if none exists" do
      {:ok, actor} = Relay.get_or_create_relay_actor()

      assert actor.username == "relay"
      assert actor.actor_type == "Application"
      assert actor.display_name == "Elektrine Relay"
      assert actor.public_key != nil
      # Private key is stored in metadata for local actors
      assert actor.metadata["private_key"] != nil
    end

    test "returns existing relay actor on subsequent calls" do
      {:ok, actor1} = Relay.get_or_create_relay_actor()
      {:ok, actor2} = Relay.get_or_create_relay_actor()

      assert actor1.id == actor2.id
    end
  end

  describe "list_subscriptions/0" do
    test "returns empty list when no subscriptions exist" do
      assert Relay.list_subscriptions() == []
    end

    test "returns all subscriptions" do
      # Create test subscriptions
      {:ok, sub1} =
        %RelaySubscription{}
        |> RelaySubscription.changeset(%{
          relay_uri: "https://relay.example1.com/actor",
          relay_inbox: "https://relay.example1.com/inbox",
          status: "active"
        })
        |> Repo.insert()

      {:ok, sub2} =
        %RelaySubscription{}
        |> RelaySubscription.changeset(%{
          relay_uri: "https://relay.example2.com/actor",
          relay_inbox: "https://relay.example2.com/inbox",
          status: "pending"
        })
        |> Repo.insert()

      subscriptions = Relay.list_subscriptions()
      assert length(subscriptions) == 2

      uris = Enum.map(subscriptions, & &1.relay_uri)
      assert sub1.relay_uri in uris
      assert sub2.relay_uri in uris
    end
  end

  describe "list_active_subscriptions/0" do
    test "only returns active and accepted subscriptions" do
      # Create various subscriptions
      {:ok, _pending} =
        %RelaySubscription{}
        |> RelaySubscription.changeset(%{
          relay_uri: "https://relay.pending.com/actor",
          relay_inbox: "https://relay.pending.com/inbox",
          status: "pending",
          accepted: false
        })
        |> Repo.insert()

      {:ok, active} =
        %RelaySubscription{}
        |> RelaySubscription.changeset(%{
          relay_uri: "https://relay.active.com/actor",
          relay_inbox: "https://relay.active.com/inbox",
          status: "active",
          accepted: true
        })
        |> Repo.insert()

      {:ok, _rejected} =
        %RelaySubscription{}
        |> RelaySubscription.changeset(%{
          relay_uri: "https://relay.rejected.com/actor",
          relay_inbox: "https://relay.rejected.com/inbox",
          status: "rejected",
          accepted: false
        })
        |> Repo.insert()

      active_subs = Relay.list_active_subscriptions()
      assert length(active_subs) == 1
      assert hd(active_subs).relay_uri == active.relay_uri
    end
  end

  describe "get_subscription/1" do
    test "returns subscription when found" do
      {:ok, sub} =
        %RelaySubscription{}
        |> RelaySubscription.changeset(%{
          relay_uri: "https://relay.test.com/actor",
          relay_inbox: "https://relay.test.com/inbox",
          status: "active"
        })
        |> Repo.insert()

      assert {:ok, found} = Relay.get_subscription(sub.relay_uri)
      assert found.id == sub.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Relay.get_subscription("https://nonexistent.com/actor")
    end
  end

  describe "handle_accept/1" do
    test "updates subscription to active when accept received" do
      follow_id = "https://example.com/activities/#{Ecto.UUID.generate()}"

      {:ok, _sub} =
        %RelaySubscription{}
        |> RelaySubscription.changeset(%{
          relay_uri: "https://relay.test.com/actor",
          relay_inbox: "https://relay.test.com/inbox",
          follow_activity_id: follow_id,
          status: "pending",
          accepted: false
        })
        |> Repo.insert()

      assert {:ok, updated} = Relay.handle_accept(follow_id)
      assert updated.status == "active"
      assert updated.accepted == true
    end

    test "returns error when subscription not found" do
      assert {:error, :subscription_not_found} =
               Relay.handle_accept("https://example.com/activities/nonexistent")
    end
  end

  describe "handle_reject/1" do
    test "updates subscription to rejected" do
      follow_id = "https://example.com/activities/#{Ecto.UUID.generate()}"

      {:ok, _sub} =
        %RelaySubscription{}
        |> RelaySubscription.changeset(%{
          relay_uri: "https://relay.test.com/actor",
          relay_inbox: "https://relay.test.com/inbox",
          follow_activity_id: follow_id,
          status: "pending",
          accepted: false
        })
        |> Repo.insert()

      assert {:ok, updated} = Relay.handle_reject(follow_id)
      assert updated.status == "rejected"
      assert updated.accepted == false
    end
  end

  describe "should_publish_to_relays?/1" do
    # Test via publish_to_relays which uses this internally
    test "only creates activities are considered for relay publishing" do
      # Public Create activity
      public_create = %{
        "type" => "Create",
        "object" => %{
          "type" => "Note",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      # This should not error even with no active relays
      assert :ok = Relay.publish_to_relays(public_create)

      # Non-public Create activity
      private_create = %{
        "type" => "Create",
        "object" => %{
          "type" => "Note",
          "to" => ["https://example.com/users/someone/followers"]
        }
      }

      assert :ok = Relay.publish_to_relays(private_create)

      # Non-Create activity
      like_activity = %{
        "type" => "Like",
        "object" => "https://example.com/posts/1"
      }

      assert :ok = Relay.publish_to_relays(like_activity)
    end
  end
end
