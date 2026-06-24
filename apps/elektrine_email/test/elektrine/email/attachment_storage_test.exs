defmodule Elektrine.Email.AttachmentStorageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Elektrine.Email.AttachmentStorage

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "elektrine-email-attachments-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:elektrine, :uploads,
      adapter: :local,
      uploads_dir: tmp_dir
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :uploads, previous_uploads)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "stores, downloads, and deletes attachments in local storage", %{tmp_dir: tmp_dir} do
    assert {:ok, metadata} =
             AttachmentStorage.upload_attachment(12, 34, "attachment_1", "hello world", %{
               "filename" => "note.txt",
               "content_type" => "text/plain"
             })

    assert metadata["storage_type"] == "local"
    assert metadata["key"] == "email-attachments/mailbox_12/message_34/attachment_1.txt"

    stored_path = Path.join(tmp_dir, metadata["key"])
    assert File.read!(stored_path) == "hello world"

    assert {:ok, "hello world"} = AttachmentStorage.download_attachment(metadata)
    assert :ok = AttachmentStorage.delete_attachment(metadata)
    refute File.exists?(stored_path)
  end

  test "sanitizes attachment IDs before generating local storage keys", %{tmp_dir: tmp_dir} do
    assert {:ok, metadata} =
             AttachmentStorage.upload_attachment(12, 34, "../evil", "hello world", %{
               "filename" => "note.txt",
               "content_type" => "text/plain"
             })

    assert metadata["key"] == "email-attachments/mailbox_12/message_34/___evil.txt"
    assert File.read!(Path.join(tmp_dir, metadata["key"])) == "hello world"
  end

  test "rejects local storage metadata that escapes the email attachment namespace" do
    metadata = %{
      "storage_type" => "local",
      "key" => "email-attachments/mailbox_12/message_34/../../../evil.txt"
    }

    assert capture_log(fn ->
             assert {:error, "Failed to download attachment"} =
                      AttachmentStorage.download_attachment(metadata)
           end) =~ "invalid_storage_key"

    assert capture_log(fn ->
             assert {:error, :invalid_storage_key} = AttachmentStorage.delete_attachment(metadata)
           end) =~ "invalid_storage_key"
  end

  test "rejects s3 metadata for unexpected buckets before storage access" do
    Application.put_env(:elektrine, :uploads,
      adapter: :s3,
      bucket: "expected-bucket",
      endpoint: "s3.example.test"
    )

    metadata = %{
      "storage_type" => "s3",
      "bucket" => "attacker-bucket",
      "key" => "email-attachments/mailbox_12/message_34/attachment_1.txt"
    }

    assert {:error, "Failed to download attachment"} =
             AttachmentStorage.download_attachment(metadata)

    assert {:error, "Invalid storage metadata"} =
             AttachmentStorage.generate_presigned_url(metadata)

    assert {:error, :invalid_storage_bucket} = AttachmentStorage.delete_attachment(metadata)
  end

  test "recognizes local and s3 attachment metadata as stored attachments" do
    assert AttachmentStorage.stored_attachment?(%{"storage_type" => "local"})
    assert AttachmentStorage.stored_attachment?(%{"storage_type" => "s3"})
    refute AttachmentStorage.stored_attachment?(%{"data" => "inline"})
  end
end
