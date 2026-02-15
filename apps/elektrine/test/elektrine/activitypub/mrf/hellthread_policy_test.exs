defmodule Elektrine.ActivityPub.MRF.HellthreadPolicyTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.MRF.HellthreadPolicy

  setup do
    # Clear any existing config
    Application.delete_env(:elektrine, :mrf_hellthread)
    :ok
  end

  describe "filter/1 - reject threshold" do
    test "rejects activities with too many mentions (using tags)" do
      Application.put_env(:elektrine, :mrf_hellthread, reject_threshold: 5)

      # Create activity with 6 mentions
      mentions =
        Enum.map(1..6, fn i ->
          %{"type" => "Mention", "href" => "https://example.com/users/user#{i}"}
        end)

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "Hello everyone!",
          "tag" => mentions
        }
      }

      assert {:reject, message} = HellthreadPolicy.filter(activity)
      assert message =~ "Too many mentions"
    end

    test "rejects activities with too many recipients (using to/cc)" do
      Application.put_env(:elektrine, :mrf_hellthread, reject_threshold: 5)

      # Create activity with many recipients
      recipients = Enum.map(1..6, fn i -> "https://example.com/users/user#{i}" end)

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "to" => recipients,
        "cc" => [],
        "object" => %{
          "type" => "Note",
          "content" => "Hello everyone!"
        }
      }

      assert {:reject, message} = HellthreadPolicy.filter(activity)
      assert message =~ "Too many mentions"
    end

    test "allows activities under reject threshold" do
      Application.put_env(:elektrine, :mrf_hellthread, reject_threshold: 10)

      mentions =
        Enum.map(1..5, fn i ->
          %{"type" => "Mention", "href" => "https://example.com/users/user#{i}"}
        end)

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "Hello everyone!",
          "tag" => mentions
        }
      }

      assert {:ok, ^activity} = HellthreadPolicy.filter(activity)
    end
  end

  describe "filter/1 - delist threshold" do
    test "delists activities with mentions above delist threshold but below reject" do
      Application.put_env(:elektrine, :mrf_hellthread,
        delist_threshold: 5,
        reject_threshold: 20
      )

      mentions =
        Enum.map(1..10, fn i ->
          %{"type" => "Mention", "href" => "https://example.com/users/user#{i}"}
        end)

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "Hello everyone!",
          "tag" => mentions
        }
      }

      assert {:ok, filtered} = HellthreadPolicy.filter(activity)
      assert filtered["object"]["_mrf_federated_timeline_removal"] == true
    end

    test "does not delist activities under delist threshold" do
      Application.put_env(:elektrine, :mrf_hellthread, delist_threshold: 10)

      mentions =
        Enum.map(1..3, fn i ->
          %{"type" => "Mention", "href" => "https://example.com/users/user#{i}"}
        end)

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "Hello everyone!",
          "tag" => mentions
        }
      }

      assert {:ok, filtered} = HellthreadPolicy.filter(activity)
      refute Map.has_key?(filtered["object"], "_mrf_federated_timeline_removal")
    end
  end

  describe "filter/1 - recipient counting" do
    test "excludes public addresses from count" do
      Application.put_env(:elektrine, :mrf_hellthread, reject_threshold: 3)

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "to" => [
          "https://www.w3.org/ns/activitystreams#Public",
          "https://example.com/users/user1",
          "https://example.com/users/user2"
        ],
        "cc" => [],
        "object" => %{
          "type" => "Note",
          "content" => "Hello!"
        }
      }

      # Only 2 actual users, so should pass
      assert {:ok, ^activity} = HellthreadPolicy.filter(activity)
    end

    test "excludes followers collection from count" do
      Application.put_env(:elektrine, :mrf_hellthread, reject_threshold: 3)

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "to" => [
          "https://example.com/users/test/followers",
          "https://example.com/users/user1",
          "https://example.com/users/user2"
        ],
        "cc" => [],
        "object" => %{
          "type" => "Note",
          "content" => "Hello!"
        }
      }

      # Only 2 actual users (followers collection excluded), so should pass
      assert {:ok, ^activity} = HellthreadPolicy.filter(activity)
    end
  end

  describe "filter/1 - non-Create activities" do
    test "passes through other activity types" do
      Application.put_env(:elektrine, :mrf_hellthread, reject_threshold: 1)

      activity = %{
        "type" => "Like",
        "actor" => "https://example.com/users/test",
        "object" => "https://example.com/posts/123"
      }

      assert {:ok, ^activity} = HellthreadPolicy.filter(activity)
    end
  end

  describe "describe/0" do
    test "returns threshold configuration" do
      Application.put_env(:elektrine, :mrf_hellthread,
        delist_threshold: 15,
        reject_threshold: 25
      )

      {:ok, description} = HellthreadPolicy.describe()

      assert description[:mrf_hellthread][:delist_threshold] == 15
      assert description[:mrf_hellthread][:reject_threshold] == 25
    end

    test "returns defaults when not configured" do
      Application.delete_env(:elektrine, :mrf_hellthread)

      {:ok, description} = HellthreadPolicy.describe()

      # Defaults are 10 and 20
      assert description[:mrf_hellthread][:delist_threshold] == 10
      assert description[:mrf_hellthread][:reject_threshold] == 20
    end
  end
end
