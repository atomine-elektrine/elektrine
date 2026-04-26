defmodule Elektrine.UploadsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Uploads

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "elektrine-uploads-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Application.put_env(:elektrine, :uploads, adapter: :local, uploads_dir: tmp_dir)

    on_exit(fn ->
      Application.put_env(:elektrine, :uploads, previous_uploads)
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, user: AccountsFixtures.user_fixture()}
  end

  test "rejects video uploads whose bytes do not match the declared type", %{
    tmp_dir: tmp_dir,
    user: user
  } do
    upload = upload_fixture(tmp_dir, "clip.mp4", "video/mp4", "not an mp4")

    assert {:error, {:invalid_file_format, _}} = Uploads.upload_chat_attachment(upload, user.id)
  end

  test "rejects text uploads containing NUL bytes", %{tmp_dir: tmp_dir, user: user} do
    upload = upload_fixture(tmp_dir, "notes.txt", "text/plain", "safe" <> <<0>> <> "hidden")

    assert {:error, {:invalid_file_format, _}} = Uploads.upload_chat_attachment(upload, user.id)
  end

  test "accepts document uploads with matching container bytes", %{tmp_dir: tmp_dir, user: user} do
    upload =
      upload_fixture(
        tmp_dir,
        "report.docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "PK\x03\x04document"
      )

    assert {:ok, %{key: "/uploads/chat-attachments/" <> _}} =
             Uploads.upload_chat_attachment(upload, user.id)
  end

  defp upload_fixture(tmp_dir, filename, content_type, content) do
    path = Path.join(tmp_dir, "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, content)

    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end
end
