defmodule Elektrine.ActivityPub.MRF.KeywordPolicyTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.MRF.KeywordPolicy

  setup do
    # Clear any existing config
    Application.delete_env(:elektrine, :mrf_keyword)
    :ok
  end

  describe "filter/1 - reject" do
    test "rejects activities matching reject patterns" do
      Application.put_env(:elektrine, :mrf_keyword, reject: ["spam phrase"])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "This contains a spam phrase in it"
        }
      }

      assert {:reject, "Blocked by keyword filter"} = KeywordPolicy.filter(activity)
    end

    test "rejects activities matching regex patterns" do
      Application.put_env(:elektrine, :mrf_keyword, reject: [~r/buy.*now/i])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "You should BUY this product NOW!"
        }
      }

      assert {:reject, "Blocked by keyword filter"} = KeywordPolicy.filter(activity)
    end

    test "allows activities not matching reject patterns" do
      Application.put_env(:elektrine, :mrf_keyword, reject: ["spam"])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "This is a normal post"
        }
      }

      assert {:ok, ^activity} = KeywordPolicy.filter(activity)
    end
  end

  describe "filter/1 - replace" do
    test "replaces matching text with replacement" do
      Application.put_env(:elektrine, :mrf_keyword, replace: [{"bad word", "****"}])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "This has a bad word in it"
        }
      }

      assert {:ok, filtered} = KeywordPolicy.filter(activity)
      assert filtered["object"]["content"] == "This has a **** in it"
    end

    test "replaces with regex patterns" do
      Application.put_env(:elektrine, :mrf_keyword, replace: [{~r/\btest\b/i, "example"}])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "This is a TEST post"
        }
      }

      assert {:ok, filtered} = KeywordPolicy.filter(activity)
      assert filtered["object"]["content"] == "This is a example post"
    end
  end

  describe "filter/1 - mark_sensitive" do
    test "marks content as sensitive when matching patterns" do
      Application.put_env(:elektrine, :mrf_keyword, mark_sensitive: ["nsfw"])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "This is NSFW content",
          "sensitive" => false
        }
      }

      assert {:ok, filtered} = KeywordPolicy.filter(activity)
      assert filtered["object"]["sensitive"] == true
    end

    test "does not mark sensitive when no match" do
      Application.put_env(:elektrine, :mrf_keyword, mark_sensitive: ["nsfw"])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "This is safe content",
          "sensitive" => false
        }
      }

      assert {:ok, filtered} = KeywordPolicy.filter(activity)
      assert filtered["object"]["sensitive"] == false
    end
  end

  describe "filter/1 - federated_timeline_removal" do
    test "flags content for removal from federated timeline" do
      Application.put_env(:elektrine, :mrf_keyword, federated_timeline_removal: ["politics"])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "Let's talk about politics today"
        }
      }

      assert {:ok, filtered} = KeywordPolicy.filter(activity)
      assert filtered["object"]["_mrf_federated_timeline_removal"] == true
    end
  end

  describe "filter/1 - Update activities" do
    test "also filters Update activities" do
      Application.put_env(:elektrine, :mrf_keyword, reject: ["spam"])

      activity = %{
        "type" => "Update",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "Updated to include spam"
        }
      }

      assert {:reject, "Blocked by keyword filter"} = KeywordPolicy.filter(activity)
    end
  end

  describe "filter/1 - non-Create/Update activities" do
    test "passes through other activity types" do
      Application.put_env(:elektrine, :mrf_keyword, reject: ["spam"])

      activity = %{
        "type" => "Like",
        "actor" => "https://example.com/users/test",
        "object" => "https://example.com/posts/123"
      }

      assert {:ok, ^activity} = KeywordPolicy.filter(activity)
    end
  end

  describe "filter/1 - checks multiple fields" do
    test "checks summary field" do
      Application.put_env(:elektrine, :mrf_keyword, reject: ["spam"])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Note",
          "content" => "Normal content",
          "summary" => "CW: spam warning"
        }
      }

      assert {:reject, "Blocked by keyword filter"} = KeywordPolicy.filter(activity)
    end

    test "checks name field" do
      Application.put_env(:elektrine, :mrf_keyword, reject: ["spam"])

      activity = %{
        "type" => "Create",
        "actor" => "https://example.com/users/test",
        "object" => %{
          "type" => "Article",
          "content" => "Normal content",
          "name" => "Spam Article Title"
        }
      }

      assert {:reject, "Blocked by keyword filter"} = KeywordPolicy.filter(activity)
    end
  end

  describe "describe/0" do
    test "returns policy configuration summary" do
      Application.put_env(:elektrine, :mrf_keyword,
        reject: ["a", "b"],
        federated_timeline_removal: ["c"],
        replace: [{"d", "e"}],
        mark_sensitive: []
      )

      {:ok, description} = KeywordPolicy.describe()

      assert description[:mrf_keyword][:reject_count] == 2
      assert description[:mrf_keyword][:federated_timeline_removal_count] == 1
      assert description[:mrf_keyword][:replace_count] == 1
      assert description[:mrf_keyword][:mark_sensitive_count] == 0
    end
  end
end
