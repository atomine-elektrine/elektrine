defmodule Elektrine.Email.AttachmentStorageTest do
  use ExUnit.Case, async: false

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

  test "recognizes local and s3 attachment metadata as stored attachments" do
    assert AttachmentStorage.stored_attachment?(%{"storage_type" => "local"})
    assert AttachmentStorage.stored_attachment?(%{"storage_type" => "s3"})
    refute AttachmentStorage.stored_attachment?(%{"data" => "inline"})
  end
end
