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
end
