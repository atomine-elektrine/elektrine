defmodule Elektrine.Email.ExportsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Email
  alias Elektrine.Email.Export
  alias Elektrine.Repo

  test "get_download_path refuses stored file paths outside the export directory" do
    user = user_fixture()

    outside_path =
      Path.join(System.tmp_dir!(), "elektrine-email-export-leak-#{unique_integer()}.txt")

    File.write!(outside_path, "secret outside export dir")

    on_exit(fn -> File.rm(outside_path) end)

    {:ok, export} =
      %Export{}
      |> Export.changeset(%{
        user_id: user.id,
        status: "completed",
        format: "mbox",
        file_path: outside_path
      })
      |> Repo.insert()

    assert {:error, :file_not_found} = Email.get_download_path(export)
  end

  defp unique_integer, do: System.unique_integer([:positive])
end
