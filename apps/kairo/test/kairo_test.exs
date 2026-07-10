defmodule KairoTest do
  use Kairo.DataCase, async: true

  import Kairo.AccountsFixtures

  describe "projects" do
    test "create_project/2 creates a user-owned project with a slug" do
      user = user_fixture()

      assert {:ok, project} =
               Kairo.create_project(user, %{
                 "name" => "Agent Memory",
                 "description" => "Research feed"
               })

      assert project.user_id == user.id
      assert project.slug == "agent-memory"
      assert project.status == "active"
      assert project.autonomy_level == 1
    end

    test "update_project/3 renames and archives, enforcing ownership" do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, project} = Kairo.create_project(user, %{"name" => "Old Name"})

      assert {:ok, renamed} = Kairo.update_project(user, project.id, %{"name" => "New Name"})
      assert renamed.name == "New Name"

      assert {:ok, archived} = Kairo.update_project(user, project.id, %{"status" => "archived"})
      assert archived.status == "archived"

      assert {:error, :not_found} =
               Kairo.update_project(other_user, project.id, %{"name" => "stolen"})
    end

    test "update_project/3 cannot reassign ownership" do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, project} = Kairo.create_project(user, %{"name" => "Mine"})

      assert {:ok, updated} =
               Kairo.update_project(user, project.id, %{
                 "name" => "Still Mine",
                 "user_id" => other_user.id
               })

      assert updated.user_id == user.id
    end

    test "update_project/3 refreshes storage accounting" do
      user = user_fixture()
      {:ok, project} = Kairo.create_project(user, %{"name" => "Storage tracked"})

      before_update =
        Elektrine.Repo.get!(Elektrine.Accounts.User, user.id).storage_used_bytes

      assert {:ok, _updated} =
               Kairo.update_project(user, project.id, %{
                 "description" => String.duplicate("project details ", 20)
               })

      after_update = Elektrine.Repo.get!(Elektrine.Accounts.User, user.id).storage_used_bytes

      assert after_update > before_update
      assert after_update == Elektrine.Accounts.Storage.calculate_user_storage(user.id)
    end

    test "create_project/2 validates database-backed string lengths" do
      user = user_fixture()

      assert {:error, changeset} =
               Kairo.create_project(user, %{"name" => String.duplicate("x", 256)})

      assert %{name: _message, slug: _slug_message} = errors_on(changeset)
    end

    test "list_projects/2 filters by status" do
      user = user_fixture()
      {:ok, active} = Kairo.create_project(user, %{"name" => "Active"})
      {:ok, archived} = Kairo.create_project(user, %{"name" => "Archived"})
      {:ok, _} = Kairo.update_project(user, archived.id, %{"status" => "archived"})

      assert [_one, _two] = Kairo.list_projects(user)
      assert [%{id: id}] = Kairo.list_projects(user, status: "active")
      assert id == active.id
    end

    test "delete_project/2 releases its sources to the inbox" do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, project} = Kairo.create_project(user, %{"name" => "Doomed"})

      {:ok, source} =
        Kairo.create_source(user, %{
          "source_type" => "markdown",
          "title" => "Keeper",
          "content" => "survives project deletion",
          "project_id" => project.id
        })

      assert {:error, :not_found} = Kairo.delete_project(other_user, project.id)
      assert {:ok, _project} = Kairo.delete_project(user, project.id)

      assert Kairo.get_project(user, project.id) == nil
      reloaded = Kairo.get_source(user, source.id)
      assert reloaded.project_id == nil
      assert reloaded.content == "survives project deletion"
    end
  end

  describe "sources" do
    test "create_source/2 ingests source payloads into the optional inbox" do
      user = user_fixture()

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "markdown",
                 "title" => "Notebook",
                 "content" => "# Kairo",
                 "tags" => "llm, research"
               })

      assert source.user_id == user.id
      assert source.project_id == nil
      assert source.status == "received"
      assert source.tags == ["llm", "research"]
      assert is_binary(source.raw_hash)
      assert source.ingested_at
    end

    test "create_source/2 enforces project ownership" do
      owner = user_fixture()
      other_user = user_fixture()
      {:ok, project} = Kairo.create_project(owner, %{"name" => "Private"})

      assert {:error, :project_not_found} =
               Kairo.create_source(other_user, %{
                 "project_id" => project.id,
                 "source_type" => "url",
                 "url" => "https://example.com"
               })
    end

    test "create_source/2 stores an encrypted source zero-knowledge" do
      user = user_fixture()

      payload = %{
        "version" => 2,
        "algorithm" => "AES-GCM",
        "iv" => Base.encode64(:crypto.strong_rand_bytes(12)),
        "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(64))
      }

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "text",
                 "title" => "Private note",
                 "content" => "this should never be stored",
                 "encrypted" => true,
                 "encrypted_content" => payload
               })

      # Plaintext is dropped; only the ciphertext envelope is kept.
      assert source.encrypted
      assert source.content == nil
      assert source.encrypted_content["ciphertext"] == payload["ciphertext"]
      # Encrypted rows are parked at "stored" (no server processing) and the
      # server computes no content hash it could use to confirm the plaintext.
      assert source.status == "stored"
      assert source.raw_hash == nil
    end

    test "create_source/2 encrypts plaintext content at rest" do
      user = user_fixture()

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "markdown",
                 "title" => "Server note",
                 "content" => "at-rest secret body"
               })

      # Reads transparently return the plaintext content...
      assert source.content == "at-rest secret body"
      assert Kairo.get_source(user, source.id).content == "at-rest secret body"

      # ...but the stored row holds a ciphertext map, not plaintext, and is not
      # flagged as a zero-knowledge source.
      row = Elektrine.Repo.get!(Kairo.Source, source.id)
      assert is_nil(row.content)
      assert is_map(row.content_encrypted)
      refute row.encrypted
      assert is_nil(row.encrypted_content)
    end

    test "update_source/3 only replaces at-rest ciphertext when content changes" do
      user = user_fixture()

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "markdown",
                 "title" => "Original title",
                 "content" => "body to keep"
               })

      row_before = Elektrine.Repo.get!(Kairo.Source, source.id)

      assert {:ok, renamed} =
               Kairo.update_source(user, source.id, %{"title" => "Renamed"})

      row_after_rename = Elektrine.Repo.get!(Kairo.Source, source.id)
      assert renamed.content == "body to keep"
      assert row_after_rename.content_encrypted == row_before.content_encrypted

      assert {:ok, cleared} = Kairo.update_source(user, source.id, %{"content" => nil})
      row_after_clear = Elektrine.Repo.get!(Kairo.Source, source.id)

      assert cleared.content == nil
      assert row_after_clear.content == nil
      assert row_after_clear.content_encrypted == nil
    end

    test "update_source/3 keeps encryption and ingest identity immutable" do
      user = user_fixture()

      payload = %{
        "version" => 2,
        "algorithm" => "AES-GCM",
        "iv" => Base.encode64(:crypto.strong_rand_bytes(12)),
        "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(64))
      }

      replacement_payload = %{
        "version" => 2,
        "algorithm" => "AES-GCM",
        "iv" => Base.encode64(:crypto.strong_rand_bytes(12)),
        "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(64))
      }

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "text",
                 "title" => "Immutable envelope",
                 "encrypted" => true,
                 "encrypted_content" => payload,
                 "raw_hash" => "blind-hash"
               })

      assert {:ok, updated} =
               Kairo.update_source(user, source.id, %{
                 "encrypted" => false,
                 "encrypted_content" => replacement_payload,
                 "raw_hash" => "replacement-hash",
                 "ingested_at" => ~U[2035-01-01 00:00:00Z]
               })

      assert updated.encrypted
      assert updated.encrypted_content == payload
      assert updated.raw_hash == "blind-hash"
      assert updated.ingested_at == source.ingested_at
    end

    test "create_source/2 requires valid HTTP(S) URLs" do
      user = user_fixture()

      for url <- [
            "javascript:alert(1)",
            "data:text/html,hello",
            "ftp://example.com/file",
            "https://user:password@example.com/private",
            "https://"
          ] do
        assert {:error, changeset} =
                 Kairo.create_source(user, %{"source_type" => "url", "url" => url})

        assert %{url: _message} = errors_on(changeset)
      end

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "url",
                 "url" => "https://example.com/article"
               })

      assert source.url == "https://example.com/article"
    end

    test "retry_url_source/2 resets an owned failed URL source" do
      user = user_fixture()
      other_user = user_fixture()

      assert {:ok, source} =
               Kairo.create_source(user, %{
                 "source_type" => "url",
                 "url" => "https://example.com/retry",
                 "status" => "failed",
                 "error_message" => "timeout",
                 "processed_at" => DateTime.utc_now() |> DateTime.truncate(:second)
               })

      assert {:error, :not_found} = Kairo.retry_url_source(other_user, source.id)
      assert {:ok, retried} = Kairo.retry_url_source(user, source.id)
      assert retried.status == "received"
      assert retried.error_message == nil
      assert retried.processed_at == nil
      assert {:error, :not_retryable} = Kairo.retry_url_source(user, source.id)
    end

    test "create_source/2 validates database-backed string and tag lengths" do
      user = user_fixture()

      assert {:error, title_changeset} =
               Kairo.create_source(user, %{
                 "source_type" => "text",
                 "title" => String.duplicate("x", 256)
               })

      assert %{title: _message} = errors_on(title_changeset)

      assert {:error, tag_changeset} =
               Kairo.create_source(user, %{
                 "source_type" => "text",
                 "title" => "Tagged",
                 "tags" => [String.duplicate("x", 101)]
               })

      assert %{tags: _message} = errors_on(tag_changeset)
    end

    test "create_source/2 rejects an encrypted source without a ciphertext payload" do
      user = user_fixture()

      assert {:error, changeset} =
               Kairo.create_source(user, %{
                 "source_type" => "text",
                 "encrypted" => true
               })

      assert %{encrypted_content: _} = errors_on(changeset)
    end

    test "create_source/2 rejects malformed encrypted payloads" do
      user = user_fixture()

      assert {:error, changeset} =
               Kairo.create_source(user, %{
                 "source_type" => "text",
                 "title" => "Malformed secret",
                 "encrypted" => true,
                 "encrypted_content" => %{
                   "version" => 1,
                   "algorithm" => "AES-GCM",
                   "iv" => Base.encode64(:crypto.strong_rand_bytes(12)),
                   "ciphertext" => Base.encode64(<<1>>)
                 }
               })

      assert %{encrypted_content: _} = errors_on(changeset)
    end

    test "create_source/2 accounts for Kairo storage usage" do
      user = user_fixture()

      assert Elektrine.Accounts.Storage.calculate_kairo_storage(user.id) == 0

      assert {:ok, _project} =
               Kairo.create_project(user, %{
                 "name" => "Storage Project",
                 "description" => "Kairo storage accounting"
               })

      assert {:ok, _source} =
               Kairo.create_source(user, %{
                 "source_type" => "markdown",
                 "title" => "Storage source",
                 "content" => String.duplicate("kairo ", 100),
                 "metadata" => %{"origin" => "test"}
               })

      assert Elektrine.Accounts.Storage.calculate_kairo_storage(user.id) > 0
      assert Elektrine.Accounts.Storage.get_storage_info(user.id).used_bytes > 0
    end

    test "create_upload_source/3 stores private files and extracts readable text" do
      user = user_fixture()
      other_user = user_fixture()
      upload = temp_upload("field-notes.md", "# Field notes\n\nhello upload", "text/markdown")

      assert {:ok, source} =
               Kairo.create_upload_source(user, upload, %{
                 "tags" => "uploads, notes",
                 "project_id" => ""
               })

      assert source.source_type == "file"
      assert source.content_format == "markdown"
      assert source.status == "compiled"
      assert source.content =~ "hello upload"
      assert source.tags == ["uploads", "notes"]
      assert source.metadata["original_filename"] == "field-notes.md"
      assert source.metadata["key"] =~ "kairo-sources/#{user.id}/"
      assert source.metadata["url"] =~ "/uploads/kairo-sources/#{user.id}/"

      assert Elektrine.Uploads.private_attachment_accessible_by_user?(
               source.metadata["key"],
               user.id
             )

      refute Elektrine.Uploads.private_attachment_accessible_by_user?(
               source.metadata["key"],
               other_user.id
             )
    end

    test "create_upload_source/3 includes stored blob bytes in storage accounting" do
      user = user_fixture()
      bytes = <<208, 207, 17, 224, 161, 177, 26, 225>> <> :binary.copy(<<0>>, 4_096)
      upload = temp_upload("archive.doc", bytes, "application/msword")

      before = Elektrine.Accounts.Storage.calculate_kairo_storage(user.id)
      assert {:ok, source} = Kairo.create_upload_source(user, upload)
      after_first = Elektrine.Accounts.Storage.calculate_kairo_storage(user.id)

      assert source.metadata["size"] == byte_size(bytes)
      assert after_first - before >= byte_size(bytes)

      duplicate_upload = temp_upload("archive.doc", bytes, "application/msword")

      assert {:ok, duplicate} =
               Kairo.create_upload_source(user, duplicate_upload, %{"tags" => "copy"})

      after_duplicate = Elektrine.Accounts.Storage.calculate_kairo_storage(user.id)

      assert duplicate.metadata["storage_key"] == source.metadata["storage_key"]
      assert after_duplicate > after_first
      assert after_duplicate - after_first < byte_size(bytes)
    end

    test "delete_source/2 only removes owned, unreferenced Kairo uploads" do
      user = user_fixture()
      other_user = user_fixture()
      content = "shared Kairo upload"

      first_upload = temp_upload("shared.txt", content, "text/plain")
      second_upload = temp_upload("shared.txt", content, "text/plain")

      assert {:ok, first} =
               Kairo.create_upload_source(user, first_upload, %{"tags" => "first"})

      assert {:ok, second} =
               Kairo.create_upload_source(user, second_upload, %{"tags" => "second"})

      assert first.id != second.id
      assert first.metadata["key"] == second.metadata["key"]

      assert {:ok, protected} =
               Kairo.update_source(user, first.id, %{
                 "metadata" => %{
                   "storage_key" => "kairo-sources/#{other_user.id}/stolen.txt",
                   "capture_label" => "editable"
                 }
               })

      assert protected.metadata["storage_key"] == first.metadata["storage_key"]
      assert protected.metadata["key"] == first.metadata["key"]
      assert protected.metadata["capture_label"] == "editable"

      assert {:ok, stored_path} =
               Elektrine.Uploads.private_attachment_local_path(first.metadata["key"])

      assert File.exists?(stored_path)
      assert {:ok, _deleted} = Kairo.delete_source(user, first.id)
      assert File.exists?(stored_path)

      foreign_key = "kairo-sources/#{other_user.id}/aa/bb/cc/foreign.txt"
      foreign_path = Path.join(["tmp/test_uploads", foreign_key])
      File.mkdir_p!(Path.dirname(foreign_path))
      File.write!(foreign_path, "other user's upload")
      on_exit(fn -> File.rm(foreign_path) end)

      assert {:ok, pointer} =
               Kairo.create_source(user, %{
                 "source_type" => "file",
                 "title" => "Untrusted metadata",
                 "metadata" => %{"storage_key" => foreign_key}
               })

      assert {:ok, _deleted} = Kairo.delete_source(user, pointer.id)
      assert File.exists?(foreign_path)

      assert {:ok, _deleted} = Kairo.delete_source(user, second.id)
      refute File.exists?(stored_path)
    end

    test "update_source/3 edits an owned source" do
      user = user_fixture()

      {:ok, source} =
        Kairo.create_source(user, %{
          "source_type" => "markdown",
          "title" => "Draft",
          "content" => "first body",
          "tags" => "old"
        })

      assert {:ok, updated} =
               Kairo.update_source(user, source.id, %{
                 "title" => "Edited",
                 "content" => "second body",
                 "tags" => "new, edited"
               })

      assert updated.title == "Edited"
      assert updated.content == "second body"
      assert updated.tags == ["new", "edited"]
      assert updated.raw_hash != source.raw_hash
      assert Kairo.get_source(user, source.id).content == "second body"
    end

    test "update_source/3 reloads the project association after moving a source" do
      user = user_fixture()
      {:ok, first_project} = Kairo.create_project(user, %{"name" => "First"})
      {:ok, second_project} = Kairo.create_project(user, %{"name" => "Second"})

      {:ok, source} =
        Kairo.create_source(user, %{
          "source_type" => "text",
          "title" => "Move me",
          "project_id" => first_project.id
        })

      assert source.project_id == first_project.id

      assert {:ok, moved} =
               Kairo.update_source(user, source.id, %{"project_id" => second_project.id})

      assert moved.project_id == second_project.id
      assert moved.project.id == second_project.id
      assert moved.project.name == "Second"
    end

    test "update_source/3 and delete_source/2 enforce ownership" do
      owner = user_fixture()
      other_user = user_fixture()

      {:ok, source} =
        Kairo.create_source(owner, %{
          "source_type" => "markdown",
          "title" => "Private",
          "content" => "owner only"
        })

      assert {:error, :not_found} =
               Kairo.update_source(other_user, source.id, %{"title" => "stolen"})

      assert {:error, :not_found} = Kairo.delete_source(other_user, source.id)
      assert Kairo.get_source(owner, source.id)
    end

    test "delete_source/2 deletes an owned source" do
      user = user_fixture()

      {:ok, source} =
        Kairo.create_source(user, %{
          "source_type" => "markdown",
          "title" => "Delete me",
          "content" => "gone soon"
        })

      assert {:ok, _deleted} = Kairo.delete_source(user, source.id)
      assert Kairo.get_source(user, source.id) == nil
    end

    test "create_source/2 is idempotent for identical content" do
      user = user_fixture()

      attrs = %{
        "source_type" => "markdown",
        "title" => "Dedup me",
        "content" => "same body",
        "tags" => "a, b"
      }

      assert {:ok, first} = Kairo.create_source(user, attrs)
      assert {:ok, second} = Kairo.create_source(user, attrs)
      assert second.id == first.id
      assert Kairo.count_sources(user) == 1

      # A different user ingesting the same content gets their own copy.
      other_user = user_fixture()
      assert {:ok, other} = Kairo.create_source(other_user, attrs)
      assert other.id != first.id
    end

    test "raw_hash is stable across a no-op update and changes with content" do
      user = user_fixture()

      {:ok, source} =
        Kairo.create_source(user, %{
          "source_type" => "markdown",
          "title" => "Stable",
          "content" => "body"
        })

      assert {:ok, unchanged} = Kairo.update_source(user, source.id, %{"title" => "Stable"})
      assert unchanged.raw_hash == source.raw_hash

      assert {:ok, changed} = Kairo.update_source(user, source.id, %{"content" => "new body"})
      assert changed.raw_hash != source.raw_hash
    end

    test "update_source/3 cannot reassign ownership" do
      user = user_fixture()
      other_user = user_fixture()

      {:ok, source} =
        Kairo.create_source(user, %{
          "source_type" => "markdown",
          "title" => "Mine",
          "content" => "owner stays fixed"
        })

      assert {:ok, updated} =
               Kairo.update_source(user, source.id, %{
                 "title" => "Still mine",
                 "user_id" => other_user.id
               })

      assert updated.user_id == user.id
    end

    test "list_sources/2 paginates with offset and count_sources/2 reports totals" do
      user = user_fixture()

      for index <- 1..3 do
        {:ok, _} =
          Kairo.create_source(user, %{
            "source_type" => "markdown",
            "title" => "Note #{index}",
            "content" => "body #{index}"
          })
      end

      assert Kairo.count_sources(user) == 3

      all = Kairo.list_sources(user)
      page = Kairo.list_sources(user, limit: 2, offset: 2)
      assert Enum.map(page, & &1.id) == all |> Enum.drop(2) |> Enum.map(& &1.id)
    end
  end

  defp temp_upload(filename, content, content_type) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kairo-upload-test-#{System.unique_integer([:positive])}-#{filename}"
      )

    File.write!(path, content)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end
end
