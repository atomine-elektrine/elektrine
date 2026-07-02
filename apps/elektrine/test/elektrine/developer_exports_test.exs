defmodule Elektrine.DeveloperExportsTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.Developer
  alias Elektrine.Developer.DataExport
  alias Elektrine.Developer.ExportWorker
  alias Elektrine.Profiles
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

  test "rejects export formats that the exporters do not implement" do
    user = user_fixture()

    assert {:error, account_changeset} =
             Developer.create_export(user.id, %{
               export_type: "account",
               format: "csv"
             })

    assert %{format: ["is not valid for account exports"]} = errors_on(account_changeset)

    assert {:error, email_changeset} =
             Developer.create_export(user.id, %{
               export_type: "email",
               format: "zip"
             })

    assert %{format: ["is not valid for email exports"]} = errors_on(email_changeset)
  end

  test "allows implemented CSV formats for social and chat exports" do
    user = user_fixture()

    assert {:ok, %DataExport{}} =
             Developer.create_export(user.id, %{
               export_type: "social",
               format: "csv"
             })

    assert {:ok, %DataExport{}} =
             Developer.create_export(user.id, %{
               export_type: "chat",
               format: "csv"
             })
  end

  test "defaults full exports to zip when no format is provided" do
    user = user_fixture()

    assert {:ok, %DataExport{} = export} =
             Developer.create_export(user.id, %{
               export_type: "full"
             })

    assert export.format == "zip"
  end

  test "keeps explicit invalid full export formats rejected" do
    user = user_fixture()

    assert {:error, changeset} =
             Developer.create_export(user.id, %{
               export_type: "full",
               format: "json"
             })

    assert %{format: ["is not valid for full exports"]} = errors_on(changeset)
  end

  test "full export includes import-ready relationship CSV files" do
    previous_export_dir = Application.get_env(:elektrine, :export_dir)
    export_dir = Path.join(System.tmp_dir!(), "elektrine-full-export-#{unique_integer()}")

    Application.put_env(:elektrine, :export_dir, export_dir)
    File.mkdir_p!(export_dir)

    on_exit(fn ->
      if previous_export_dir do
        Application.put_env(:elektrine, :export_dir, previous_export_dir)
      else
        Application.delete_env(:elektrine, :export_dir)
      end

      File.rm_rf(export_dir)
    end)

    user = user_fixture(%{username: "fullexport", handle: "fullexport"})
    followed = user_fixture(%{username: "fullfollow", handle: "fullfollow"})
    muted = user_fixture(%{username: "fullmute", handle: "fullmute"})
    blocked = user_fixture(%{username: "fullblock", handle: "fullblock"})

    assert {:ok, _follow} = Profiles.follow_user(user.id, followed.id)
    assert {:ok, _mute} = Accounts.mute_user(user.id, muted.id)
    assert {:ok, _block} = Accounts.block_user(user.id, blocked.id)
    assert {:ok, _domain_block} = Accounts.block_domain(user.id, "blocked.example")

    {:ok, export} =
      Developer.create_export(user.id, %{
        export_type: "full",
        format: "zip"
      })

    assert :ok = ExportWorker.perform(%Oban.Job{args: %{"export_id" => export.id}})

    completed = Developer.get_export(user.id, export.id)
    assert completed.status == "completed"
    assert completed.file_path

    {:ok, files} = :zip.extract(String.to_charlist(completed.file_path), [:memory])

    zip_entries =
      Map.new(files, fn {name, content} ->
        {to_string(name), to_string(content)}
      end)

    local_domain = ActivityPub.instance_domain()

    assert zip_entries["following_accounts.csv"] =~ "Account address\n"
    assert zip_entries["following_accounts.csv"] =~ "fullfollow@#{local_domain}"
    assert zip_entries["muted_accounts.csv"] =~ "fullmute@#{local_domain}"
    assert zip_entries["blocked_accounts.csv"] =~ "fullblock@#{local_domain}"
    assert zip_entries["blocked_domains.csv"] =~ "Domain\nblocked.example"

    manifest = Jason.decode!(zip_entries["export_manifest.json"])

    assert manifest["schema_version"] == 1
    assert manifest["export_type"] == "full"
    assert manifest["counts"]["total"] >= 4

    assert Enum.any?(manifest["files"], &(&1["path"] == "account.json"))
    assert Enum.any?(manifest["files"], &(&1["path"] == "following_accounts.csv"))

    assert manifest["relationship_imports"]["follows"] == %{
             "path" => "following_accounts.csv",
             "type" => "follows",
             "field" => "file",
             "header" => "Account address"
           }

    assert manifest["relationship_imports"]["domain_blocks"]["type"] == "domain_blocks"
  end

  defp unique_integer, do: System.unique_integer([:positive])
end
