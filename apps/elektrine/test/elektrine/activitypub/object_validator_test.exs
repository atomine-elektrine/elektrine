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
end
