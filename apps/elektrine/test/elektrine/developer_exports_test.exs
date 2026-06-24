defmodule Elektrine.DeveloperExportsTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer
  alias Elektrine.Developer.DataExport
  alias Elektrine.Repo

  test "creates and enqueues exports in one step" do
    user = user_fixture()

    assert {:ok, %DataExport{} = export} =
             Developer.create_export_and_enqueue(user.id, %{
               export_type: "account",
               format: "json"
             })

    export = Developer.get_export(user.id, export.id)

    assert export.status in ["processing", "completed"]
    assert export.user_id == user.id
  end

  test "delete_export does not remove files outside the configured export directory" do
    user = user_fixture()

    outside_path =
      Path.join(System.tmp_dir!(), "elektrine-export-outside-#{unique_integer()}.txt")

    File.write!(outside_path, "do not delete")

    on_exit(fn -> File.rm(outside_path) end)

    {:ok, export} =
      Developer.create_export(user.id, %{
        export_type: "account",
        format: "json"
      })

    {:ok, export} = Developer.complete_export(export, outside_path, 13, 1)

    assert {:ok, _deleted_export} = Developer.delete_export(export)
    assert File.exists?(outside_path)
    refute Repo.get(DataExport, export.id)
  end

  defp unique_integer, do: System.unique_integer([:positive])
end
