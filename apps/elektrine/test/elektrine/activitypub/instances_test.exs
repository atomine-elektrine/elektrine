defmodule Elektrine.ActivityPub.InstancesTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.{Instance, Instances}
  alias Elektrine.Repo

  describe "get_or_create_instance/1" do
    test "is idempotent across case variants" do
      assert {:ok, first} = Instances.get_or_create_instance("Tooting.CH")
      assert {:ok, second} = Instances.get_or_create_instance("tooting.ch")

      assert first.id == second.id

      domains =
        Instance
        |> Repo.all()
        |> Enum.map(& &1.domain)

      assert domains == ["tooting.ch"]
    end
  end
end
