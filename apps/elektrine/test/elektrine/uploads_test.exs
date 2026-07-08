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

  test "stores uploads with non-ASCII filenames under ASCII-safe paths", %{
    tmp_dir: tmp_dir,
    user: user
  } do
    upload = upload_fixture(tmp_dir, "头像.txt", "text/plain", "safe text")

    assert {:ok, %{key: "/uploads/chat-attachments/" <> stored_filename}} =
             Uploads.upload_chat_attachment(upload, user.id)

    assert String.ends_with?(stored_filename, ".txt")
    refute stored_filename =~ "file"
    refute stored_filename =~ "头像"
  end

  test "stores duplicate per-user content at the same content-addressed path", %{
    tmp_dir: tmp_dir,
    user: user
  } do
    content = "same file bytes"
    expected_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    upload_a = upload_fixture(tmp_dir, "first.txt", "text/plain", content)
    upload_b = upload_fixture(tmp_dir, "second.txt", "text/plain", content)

    assert {:ok, %{key: key_a, sha256: ^expected_hash}} =
             Uploads.upload_chat_attachment(upload_a, user.id)

    assert {:ok, %{key: key_b, sha256: ^expected_hash}} =
             Uploads.upload_chat_attachment(upload_b, user.id)

    assert key_a == key_b
    assert key_a =~ "/uploads/chat-attachments/#{user.id}/#{String.slice(expected_hash, 0, 2)}/"
    assert String.ends_with?(key_a, "#{expected_hash}.txt")

    stored_files =
      tmp_dir
      |> Path.join("chat-attachments")
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)

    assert length(stored_files) == 1
  end

  test "returns anonymized filenames in upload metadata", %{tmp_dir: tmp_dir, user: user} do
    content = "private receipt contents"
    expected_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    upload = upload_fixture(tmp_dir, "tax-return-2026.txt", "text/plain", content)

    assert {:ok, %{filename: filename, sha256: ^expected_hash}} =
             Uploads.upload_chat_attachment(upload, user.id)

    assert filename == "#{expected_hash}.txt"
    refute filename =~ "tax-return"
  end

  test "stores image attachment metadata before cleaning stripped temp file", %{
    tmp_dir: tmp_dir,
    user: user
  } do
    upload = upload_fixture(tmp_dir, "pixel.png", "image/png", tiny_png())

    assert Code.ensure_loaded?(Image)
    assert {:ok, _image} = Image.open(upload.path)

    assert {:ok, %{key: "/uploads/chat-attachments/" <> stored_filename, sha256: sha256}} =
             Uploads.upload_chat_attachment(upload, user.id)

    assert String.ends_with?(stored_filename, ".png")
    assert is_binary(sha256)
    refute File.exists?(upload.path <> "_stripped.png")
    assert File.exists?(Path.join([tmp_dir, "chat-attachments", stored_filename]))
  end

  test "private S3 attachment URLs use the authenticated app proxy" do
    Application.put_env(:elektrine, :uploads, adapter: :s3)

    assert Uploads.attachment_url("chat-attachments/private.jpg", %{type: "dm"}) =~
             "/api/private-attachments/"
  end

  test "accepts voice messages with allowed MIME type and matching bytes", %{
    tmp_dir: tmp_dir,
    user: user
  } do
    audio = <<26, 69, 223, 163, "audio">>
    expected_hash = :crypto.hash(:sha256, audio) |> Base.encode16(case: :lower)
    expected_filename = "#{expected_hash}.webm"

    assert {:ok,
            %{
              key: "/uploads/voice-messages/" <> stored_filename,
              filename: ^expected_filename
            }} =
             Uploads.upload_voice_message(
               audio,
               "private-meeting.webm",
               "audio/webm",
               user.id
             )

    assert File.exists?(Path.join([tmp_dir, "voice-messages", stored_filename]))
  end

  test "returns anonymized filenames for voice metadata", %{user: user} do
    audio = <<26, 69, 223, 163, "audio">>
    expected_hash = :crypto.hash(:sha256, audio) |> Base.encode16(case: :lower)

    assert {:ok, %{filename: filename, sha256: ^expected_hash}} =
             Uploads.upload_voice_message(
               audio,
               "secret-note.webm",
               "audio/webm",
               user.id
             )

    assert filename == "#{expected_hash}.webm"
    refute filename =~ "secret"
  end

  test "rejects voice messages with disallowed MIME types", %{tmp_dir: tmp_dir, user: user} do
    assert {:error, {:invalid_file_type, _}} =
             Uploads.upload_voice_message(
               <<26, 69, 223, 163, "audio">>,
               "clip.html",
               "text/html",
               user.id
             )

    refute File.exists?(Path.join(tmp_dir, "voice-messages"))
  end

  test "rejects voice messages whose bytes do not match the declared type", %{
    tmp_dir: tmp_dir,
    user: user
  } do
    assert {:error, {:invalid_file_format, _}} =
             Uploads.upload_voice_message("not webm", "clip.webm", "audio/webm", user.id)

    refute File.exists?(Path.join(tmp_dir, "voice-messages"))
  end

  test "malformed local delete keys do not normalize into deletable upload paths", %{
    tmp_dir: tmp_dir
  } do
    avatar_dir = Path.join(tmp_dir, "avatars")
    File.mkdir_p!(avatar_dir)
    victim_path = Path.join(avatar_dir, "victim.txt")
    File.write!(victim_path, "keep")

    assert {:error, :invalid_upload_key} =
             Uploads.delete_uploaded_file("uploads/uploads/avatars/victim.txt")

    assert File.read!(victim_path) == "keep"

    assert {:error, :invalid_upload_key} =
             Uploads.delete_uploaded_file("/uploads//avatars/victim.txt")

    assert File.read!(victim_path) == "keep"
  end

  defp upload_fixture(tmp_dir, filename, content_type, content) do
    path = Path.join(tmp_dir, "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, content)

    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp tiny_png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )
  end
end
