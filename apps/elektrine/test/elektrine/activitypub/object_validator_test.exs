defmodule Elektrine.ActivityPub.ObjectValidatorTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.ObjectValidator

  describe "validate/1 announce object lists" do
    test "accepts announce with object list of URIs/maps" do
      activity = %{
        "id" => "https://remote.example/activities/1",
        "type" => "Announce",
        "actor" => "https://remote.example/users/alice",
        "object" => [
          "https://remote.example/notes/1",
          %{"id" => "https://remote.example/notes/2", "type" => "Note"}
        ]
      }

      assert {:ok, _} = ObjectValidator.validate(activity)
    end

    test "rejects announce with invalid object list entries" do
      activity = %{
        "id" => "https://remote.example/activities/2",
        "type" => "Announce",
        "actor" => "https://remote.example/users/alice",
        "object" => [
          "https://remote.example/notes/1",
          123
        ]
      }

      assert {:error, "Announce activity has invalid object list"} =
               ObjectValidator.validate(activity)
    end
  end

  describe "validate/1 move activities" do
    test "accepts valid move activity" do
      activity = %{
        "id" => "https://old.example/activities/move/1",
        "type" => "Move",
        "actor" => "https://old.example/users/alice",
        "object" => "https://old.example/users/alice",
        "target" => "https://new.example/users/alice"
      }

      assert {:ok, _} = ObjectValidator.validate(activity)
    end

    test "rejects move activity missing target" do
      activity = %{
        "id" => "https://old.example/activities/move/2",
        "type" => "Move",
        "actor" => "https://old.example/users/alice",
        "object" => "https://old.example/users/alice"
      }

      assert {:error, "Move activity missing target"} = ObjectValidator.validate(activity)
    end
  end

  describe "validate/1 actor host safety" do
    test "rejects actor URIs pointing at private hosts" do
      activity = %{
        "id" => "https://remote.example/activities/3",
        "type" => "Follow",
        "actor" => "http://127.0.0.1/users/alice",
        "object" => "https://remote.example/users/bob"
      }

      assert {:error, "Invalid actor URI"} = ObjectValidator.validate(activity)
    end
  end

  describe "validate/1 embedded object guardrails" do
    test "rejects Create when object actor differs from activity actor" do
      activity =
        create_note_activity(%{
          "actor" => "https://remote.example/users/alice",
          "object" => %{
            "id" => "https://evil.example/notes/#{System.unique_integer([:positive])}",
            "actor" => "https://evil.example/users/mallory",
            "attributedTo" => "https://evil.example/users/mallory"
          }
        })

      assert {:error, "Object actor does not match activity actor"} =
               ObjectValidator.validate(activity)
    end

    test "rejects Create when object addressing conflicts with activity addressing" do
      activity =
        create_note_activity(%{
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "object" => %{"to" => ["https://remote.example/users/bob"]}
        })

      assert {:error, "Object to does not match activity to"} =
               ObjectValidator.validate(activity)
    end

    test "normalizes supported quote URL variants and attachment maps" do
      activity =
        create_note_activity(%{
          "object" => %{
            "quoteUri" => "https://remote.example/notes/quoted",
            "attachment" => %{
              "type" => "Image",
              "mediaType" => "image/png",
              "url" => "https://cdn.example/image.png"
            }
          }
        })

      assert {:ok, validated} = ObjectValidator.validate(activity)
      assert validated["object"]["quoteUrl"] == "https://remote.example/notes/quoted"
      assert [%{"type" => "Image"}] = validated["object"]["attachment"]
    end

    test "rejects unsafe attachment URLs" do
      activity =
        create_note_activity(%{
          "object" => %{
            "attachment" => [
              %{"type" => "Image", "mediaType" => "image/png", "url" => "http://127.0.0.1/x.png"}
            ]
          }
        })

      assert {:error, "Content object has invalid attachment"} =
               ObjectValidator.validate(activity)
    end

    test "rejects invalid mention and emoji tags" do
      mention_activity =
        create_note_activity(%{
          "object" => %{
            "tag" => [%{"type" => "Mention", "href" => "http://127.0.0.1/users/bob"}]
          }
        })

      assert {:error, "Content object has invalid tag"} =
               ObjectValidator.validate(mention_activity)

      emoji_activity =
        create_note_activity(%{
          "object" => %{
            "tag" => [%{"type" => "Emoji", "name" => ":bad:", "icon" => %{"url" => "notaurl"}}]
          }
        })

      assert {:error, "Content object has invalid tag"} =
               ObjectValidator.validate(emoji_activity)
    end

    test "validates Question poll options" do
      valid =
        create_note_activity(%{
          "object" => %{
            "type" => "Question",
            "content" => "Pick one",
            "oneOf" => [
              %{"type" => "Note", "name" => "Yes"},
              %{"type" => "Note", "name" => "No"}
            ]
          }
        })

      assert {:ok, _} = ObjectValidator.validate(valid)

      invalid =
        create_note_activity(%{
          "object" => %{
            "type" => "Question",
            "content" => "Pick one",
            "oneOf" => [%{"type" => "Note", "name" => ""}]
          }
        })

      assert {:error, "Question object has invalid options"} =
               ObjectValidator.validate(invalid)
    end
  end

  defp create_note_activity(overrides) do
    actor = Map.get(overrides, "actor", "https://remote.example/users/alice")
    to = Map.get(overrides, "to", ["https://www.w3.org/ns/activitystreams#Public"])
    cc = Map.get(overrides, "cc", [])
    object_overrides = Map.get(overrides, "object", %{})

    object =
      Map.merge(
        %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "actor" => actor,
          "attributedTo" => actor,
          "content" => "hello",
          "to" => to,
          "cc" => cc
        },
        object_overrides
      )

    %{
      "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => actor,
      "to" => to,
      "cc" => cc,
      "object" => object
    }
  end
end
