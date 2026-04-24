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

  describe "Instance.changeset/2" do
    test "normalizes domains and recognizes both unique constraint names" do
      changeset = Instance.changeset(%Instance{}, %{domain: " HTTPS://Tooting.CH "})

      assert Ecto.Changeset.get_change(changeset, :domain) == "tooting.ch"

      constraint_names = Enum.map(changeset.constraints, & &1.constraint)

      assert "activitypub_instances_domain_ci_unique" in constraint_names
      assert "activitypub_instances_domain_index" in constraint_names
    end
  end
end
