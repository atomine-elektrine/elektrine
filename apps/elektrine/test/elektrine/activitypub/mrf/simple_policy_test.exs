defmodule Elektrine.ActivityPub.MRF.SimplePolicyTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Instance
  alias Elektrine.ActivityPub.MRF.SimplePolicy
  alias Elektrine.Repo

  setup do
    # Clear the ETS cache before each test
    SimplePolicy.invalidate_cache()
    :ok
  end

  describe "filter/1 - reject (blocked)" do
    test "rejects activities from blocked instances" do
      # Create a blocked instance
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "blocked.example.com", blocked: true})
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://blocked.example.com/users/test",
        "object" => %{"type" => "Note", "content" => "test"}
      }

      assert {:reject, "[SimplePolicy] host is blocked"} = SimplePolicy.filter(activity)
    end

    test "allows activities from non-blocked instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "allowed.example.com", blocked: false})
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://allowed.example.com/users/test",
        "object" => %{"type" => "Note", "content" => "test"}
      }

      assert {:ok, ^activity} = SimplePolicy.filter(activity)
    end
  end

  describe "filter/1 - media_removal" do
    test "removes media attachments from media_removal instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "media.example.com", media_removal: true})
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://media.example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "test",
          "attachment" => [
            %{"type" => "Image", "url" => "https://media.example.com/image.jpg"}
          ]
        }
      }

      assert {:ok, filtered} = SimplePolicy.filter(activity)
      refute Map.has_key?(filtered["object"], "attachment")
    end

    test "preserves attachments from non-media_removal instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "normal.example.com", media_removal: false})
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://normal.example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "test",
          "attachment" => [
            %{"type" => "Image", "url" => "https://normal.example.com/image.jpg"}
          ]
        }
      }

      assert {:ok, filtered} = SimplePolicy.filter(activity)
      assert Map.has_key?(filtered["object"], "attachment")
    end
  end

  describe "filter/1 - media_nsfw" do
    test "marks content as sensitive from media_nsfw instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "nsfw.example.com", media_nsfw: true})
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://nsfw.example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "test",
          "sensitive" => false
        }
      }

      assert {:ok, filtered} = SimplePolicy.filter(activity)
      assert filtered["object"]["sensitive"] == true
    end
  end

  describe "filter/1 - federated_timeline_removal" do
    test "moves Public to CC for federated_timeline_removal instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "ftl.example.com", federated_timeline_removal: true})
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://ftl.example.com/users/test",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => ["https://ftl.example.com/users/test/followers"],
        "object" => %{"type" => "Note", "content" => "test"}
      }

      assert {:ok, filtered} = SimplePolicy.filter(activity)
      refute "https://www.w3.org/ns/activitystreams#Public" in filtered["to"]
      assert "https://www.w3.org/ns/activitystreams#Public" in filtered["cc"]
    end
  end

  describe "filter/1 - followers_only" do
    test "forces posts to followers-only from followers_only instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "fo.example.com", followers_only: true})
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://fo.example.com/users/test",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => ["https://fo.example.com/users/test/followers"],
        "object" => %{"type" => "Note", "content" => "test"}
      }

      assert {:ok, filtered} = SimplePolicy.filter(activity)
      refute "https://www.w3.org/ns/activitystreams#Public" in filtered["to"]
      refute "https://www.w3.org/ns/activitystreams#Public" in filtered["cc"]
    end
  end

  describe "filter/1 - report_removal" do
    test "rejects Flag activities from report_removal instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "report.example.com", report_removal: true})
        |> Repo.insert()

      activity = %{
        "type" => "Flag",
        "actor" => "https://report.example.com/users/test",
        "object" => ["https://our.instance/users/victim"]
      }

      assert {:reject, "[SimplePolicy] host in report_removal list"} =
               SimplePolicy.filter(activity)
    end
  end

  describe "filter/1 - reject_deletes" do
    test "rejects Delete activities from reject_deletes instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "nodelete.example.com", reject_deletes: true})
        |> Repo.insert()

      activity = %{
        "type" => "Delete",
        "actor" => "https://nodelete.example.com/users/test",
        "object" => "https://nodelete.example.com/posts/123"
      }

      assert {:reject, "[SimplePolicy] host in reject_deletes list"} =
               SimplePolicy.filter(activity)
    end
  end

  describe "filter/1 - avatar_removal" do
    test "removes avatar from Person objects from avatar_removal instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "noavatar.example.com", avatar_removal: true})
        |> Repo.insert()

      person = %{
        "type" => "Person",
        "id" => "https://noavatar.example.com/users/test",
        "name" => "Test User",
        "icon" => %{
          "type" => "Image",
          "url" => "https://noavatar.example.com/avatar.jpg"
        }
      }

      assert {:ok, filtered} = SimplePolicy.filter(person)
      refute Map.has_key?(filtered, "icon")
    end
  end

  describe "filter/1 - banner_removal" do
    test "removes banner from Person objects from banner_removal instances" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "nobanner.example.com", banner_removal: true})
        |> Repo.insert()

      person = %{
        "type" => "Person",
        "id" => "https://nobanner.example.com/users/test",
        "name" => "Test User",
        "image" => %{
          "type" => "Image",
          "url" => "https://nobanner.example.com/banner.jpg"
        }
      }

      assert {:ok, filtered} = SimplePolicy.filter(person)
      refute Map.has_key?(filtered, "image")
    end
  end

  describe "wildcard domain matching" do
    test "matches wildcard domains" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "*.spam.example.com", blocked: true})
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://subdomain.spam.example.com/users/test",
        "object" => %{"type" => "Note", "content" => "spam"}
      }

      assert {:reject, "[SimplePolicy] host is blocked"} = SimplePolicy.filter(activity)
    end

    test "wildcard does NOT match base domain (standard behavior)" do
      # Standard wildcard behavior: *.bad.com matches sub.bad.com but NOT bad.com
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "*.bad.com", blocked: true})
        |> Repo.insert()

      # Activity from sub.bad.com should be blocked
      subdomain_activity = %{
        "type" => "Create",
        "actor" => "https://sub.bad.com/users/test",
        "object" => %{"type" => "Note", "content" => "test"}
      }

      assert {:reject, "[SimplePolicy] host is blocked"} = SimplePolicy.filter(subdomain_activity)

      # Activity from base bad.com should NOT be blocked by *.bad.com
      base_activity = %{
        "type" => "Create",
        "actor" => "https://bad.com/users/test",
        "object" => %{"type" => "Note", "content" => "test"}
      }

      assert {:ok, ^base_activity} = SimplePolicy.filter(base_activity)
    end

    test "wildcard does not match unrelated domains" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "*.spam.com", blocked: true})
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://notspam.com/users/test",
        "object" => %{"type" => "Note", "content" => "test"}
      }

      assert {:ok, ^activity} = SimplePolicy.filter(activity)
    end
  end

  describe "caching" do
    test "invalidate_cache/1 clears cache for specific host" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "cached.example.com", blocked: true})
        |> Repo.insert()

      # First call populates cache
      assert true = SimplePolicy.host_has_policy?("cached.example.com", :blocked)

      # Invalidate cache
      SimplePolicy.invalidate_cache("cached.example.com")

      # Should still work (repopulates from DB)
      assert true = SimplePolicy.host_has_policy?("cached.example.com", :blocked)
    end

    test "invalidate_cache/0 clears entire cache" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{domain: "cached2.example.com", blocked: true})
        |> Repo.insert()

      # Populate cache
      assert true = SimplePolicy.host_has_policy?("cached2.example.com", :blocked)

      # Clear all cache
      SimplePolicy.invalidate_cache()

      # Should still work
      assert true = SimplePolicy.host_has_policy?("cached2.example.com", :blocked)
    end
  end

  describe "describe/0" do
    test "returns empty when transparency disabled" do
      # Transparency is disabled by default in test
      assert {:ok, result} = SimplePolicy.describe()
      assert result == %{}
    end
  end

  describe "multiple policies combined" do
    test "applies multiple policies from same instance" do
      {:ok, _instance} =
        %Instance{}
        |> Instance.changeset(%{
          domain: "multi.example.com",
          media_nsfw: true,
          federated_timeline_removal: true
        })
        |> Repo.insert()

      activity = %{
        "type" => "Create",
        "actor" => "https://multi.example.com/users/test",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => ["https://multi.example.com/users/test/followers"],
        "object" => %{
          "type" => "Note",
          "content" => "test",
          "sensitive" => false
        }
      }

      assert {:ok, filtered} = SimplePolicy.filter(activity)

      # Should have sensitive marked true
      assert filtered["object"]["sensitive"] == true

      # Should have Public moved from to to cc
      refute "https://www.w3.org/ns/activitystreams#Public" in filtered["to"]
      assert "https://www.w3.org/ns/activitystreams#Public" in filtered["cc"]
    end
  end
end
