defmodule Elektrine.DeveloperExportsTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer
  alias Elektrine.Developer.DataExport

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
end
