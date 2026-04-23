defmodule Elektrine.DriveTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.{Accounts, Drive, Repo}

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(System.tmp_dir!(), "elektrine-drive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.put_env(:elektrine, :uploads,
      adapter: :local,
      uploads_dir: tmp_dir
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :uploads, previous_uploads)
      File.rm_rf(tmp_dir)
    end)

    {:ok, user: user_fixture(), tmp_dir: tmp_dir}
  end

  test "upload_file stores file metadata and content", %{user: user} do
    upload = temp_upload("quarterly-report.txt", "quarterly numbers")

    assert {:ok, file} = Drive.upload_file(user, "reports/2026", upload)
    assert file.path == "reports/2026/quarterly-report.txt"
    assert file.original_filename == "quarterly-report.txt"
    assert file.size == byte_size("quarterly numbers")
    assert {:ok, "quarterly numbers"} = Drive.read_file(file)

    [stored] = Drive.list_files(user.id)
    assert stored.id == file.id
    assert Drive.storage_used(user.id) == byte_size("quarterly numbers")
  end

  test "create_share and revoke_share manage public links", %{user: user} do
    upload = temp_upload("shared.pdf", "%PDF-1.4 fake")
    assert {:ok, file} = Drive.upload_file(user, "", upload)

    assert {:ok, share} = Drive.create_share(user.id, file.id, %{expires_in: "7d"})
    share_id = share.id
    assert %Drive.FileShare{id: ^share_id} = Drive.get_active_share(share.token)
    assert share.expires_at

    assert {:ok, updated_share} = Drive.increment_share_download_count(share)
    assert updated_share.download_count == 1

    assert {:ok, _revoked} = Drive.revoke_share(user.id, share.id)
    assert is_nil(Drive.get_active_share(share.token))
  end

  test "list_folder returns immediate folders and files", %{user: user} do
    assert {:ok, _} =
             Drive.upload_file(user, "projects/alpha", temp_upload("readme.txt", "alpha"))

    assert {:ok, _} = Drive.upload_file(user, "projects/beta", temp_upload("notes.txt", "beta"))
    assert {:ok, root_file} = Drive.upload_file(user, "", temp_upload("todo.txt", "root"))

    assert {:ok, root_view} = Drive.list_folder(user.id, "")
    assert Enum.map(root_view.folders, & &1.path) == ["projects"]
    assert Enum.map(root_view.files, & &1.id) == [root_file.id]

    assert {:ok, project_view} = Drive.list_folder(user.id, "projects")

    assert Enum.sort(Enum.map(project_view.folders, & &1.path)) == [
             "projects/alpha",
             "projects/beta"
           ]

    assert project_view.files == []
  end

  test "can create, rename, and move folders", %{user: user} do
    assert {:ok, folder} = Drive.create_folder(user.id, "workspace/drafts")
    assert folder.path == "workspace/drafts"

    assert {:ok, moved_path} = Drive.rename_folder(user.id, "workspace/drafts", "plans")
    assert moved_path == "workspace/plans"

    assert {:ok, final_path} = Drive.move_folder(user.id, "workspace/plans", "archive/2026")
    assert final_path == "archive/2026/plans"

    assert {:ok, view} = Drive.list_folder(user.id, "archive/2026")
    assert Enum.map(view.folders, & &1.path) == ["archive/2026/plans"]
  end

  test "supports search and sort in folder views", %{user: user} do
    assert {:ok, _} = Drive.upload_file(user, "", temp_upload("zeta.txt", "12345"))
    assert {:ok, _} = Drive.upload_file(user, "", temp_upload("alpha.txt", "1"))

    assert {:ok, search_view} = Drive.list_folder(user.id, "", %{q: "alp"})
    assert Enum.map(search_view.files, & &1.original_filename) == ["alpha.txt"]

    assert {:ok, sorted_view} = Drive.list_folder(user.id, "", %{sort: "name_desc"})
    assert Enum.map(sorted_view.files, & &1.original_filename) == ["zeta.txt", "alpha.txt"]
  end

  test "expired shares are no longer active", %{user: user} do
    assert {:ok, file} = Drive.upload_file(user, "", temp_upload("shared.txt", "expiring"))
    assert {:ok, share} = Drive.create_share(user.id, file.id, %{expires_in: "1d"})

    expired_share =
      share
      |> Ecto.Changeset.change(
        expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

    assert is_nil(Drive.get_active_share(expired_share.token))
  end

  test "share links can be password protected and inline viewable", %{user: user} do
    assert {:ok, file} = Drive.upload_file(user, "", temp_upload("preview.txt", "hello world"))

    assert {:ok, share} =
             Drive.create_share(user.id, file.id, %{
               access_level: "view",
               password: "secret-pass"
             })

    share = Repo.preload(share, :stored_file)

    assert Drive.share_requires_password?(share)
    assert Drive.verify_share_password(share, "secret-pass")
    refute Drive.verify_share_password(share, "wrong-pass")
    assert Drive.share_inline_view?(share)
  end

  test "html shares are never inline viewable", %{user: user} do
    upload = temp_upload("preview.html", "<script>alert(1)</script>")
    upload = %{upload | content_type: "text/html"}

    assert {:ok, file} = Drive.upload_file(user, "", upload)
    assert {:ok, share} = Drive.create_share(user.id, file.id, %{access_level: "view"})

    share = Repo.preload(share, :stored_file)

    refute Drive.share_inline_view?(share)
  end

  test "uploading the same path replaces the existing file", %{user: user} do
    assert {:ok, first} = Drive.upload_file(user, "docs", temp_upload("notes.txt", "one"))
    assert {:ok, second} = Drive.upload_file(user, "docs", temp_upload("notes.txt", "two two"))

    assert first.id == second.id
    assert Drive.storage_used(user.id) == byte_size("two two")
    assert {:ok, "two two"} = Drive.read_file(second)

    refute File.exists?(Path.join(uploads_dir(), first.storage_key))
  end

  test "can rename, move, and bulk delete files", %{user: user} do
    assert {:ok, file} = Drive.upload_file(user, "drafts", temp_upload("notes.txt", "hello"))
    assert {:ok, _folder} = Drive.create_folder(user.id, "archive")

    assert {:ok, renamed} = Drive.rename_file(user.id, file.id, "ideas.txt")
    assert renamed.path == "drafts/ideas.txt"

    assert {:ok, moved} = Drive.move_file(user.id, renamed.id, "archive")
    assert moved.path == "archive/ideas.txt"

    assert :ok = Drive.bulk_delete(user.id, ["file:#{moved.id}"])
    assert is_nil(Drive.get_file(user.id, moved.id))
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        username: "drive#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    user
  end

  defp temp_upload(filename, content) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, content)

    %Plug.Upload{
      path: path,
      filename: filename,
      content_type: MIME.from_path(filename) || "application/octet-stream"
    }
  end

  defp uploads_dir do
    Application.get_env(:elektrine, :uploads, [])[:uploads_dir]
  end
end
