defmodule ElektrineWeb.API.MediaAttachmentControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages
  alias ElektrineWeb.API.MediaAttachmentController

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "elektrine-media-controller-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Application.put_env(:elektrine, :uploads, adapter: :local, uploads_dir: tmp_dir)

    on_exit(fn ->
      Application.put_env(:elektrine, :uploads, previous_uploads)
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "create/2" do
    test "uploads a timeline media attachment", %{conn: conn, tmp_dir: tmp_dir} do
      user = user_fixture()
      upload = upload_fixture(tmp_dir, "sample.png", "image/png", png_bytes())

      conn =
        conn
        |> assign(:current_user, user)
        |> MediaAttachmentController.create(%{
          "file" => upload,
          "description" => "Diagram preview"
        })

      assert %{
               "description" => "Diagram preview",
               "id" => id,
               "preview_url" => preview_url,
               "type" => "image",
               "url" => url
             } = json_response(conn, 201)

      assert is_binary(id)
      assert url =~ "/uploads/timeline-attachments/"
      assert preview_url == url

      key = Base.url_decode64!(id, padding: false)
      assert String.starts_with?(key, "/uploads/timeline-attachments/")
    end

    test "requires a media file", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> MediaAttachmentController.create(%{"description" => "Missing file"})

      assert %{"error" => "media file is required"} = json_response(conn, 422)
    end
  end

  describe "show/2" do
    test "returns an encoded timeline attachment", %{conn: conn} do
      key = "/uploads/timeline-attachments/test/image.png"
      id = Base.url_encode64(key, padding: false)

      conn = MediaAttachmentController.show(conn, %{"id" => id})

      assert %{
               "id" => ^id,
               "type" => "image",
               "url" => ^key,
               "preview_url" => ^key
             } = json_response(conn, 200)
    end

    test "rejects unrelated encoded attachment keys", %{conn: conn} do
      id = Base.url_encode64("/uploads/chat-attachments/test/file.png", padding: false)

      conn = MediaAttachmentController.show(conn, %{"id" => id})

      assert %{"error" => "media attachment not found"} = json_response(conn, 404)
    end
  end

  describe "update/2" do
    test "updates attachment description and focus for the owner", %{conn: conn} do
      user = user_fixture()
      media_url = "/uploads/timeline-attachments/#{user.id}/image.png"
      post = media_post_fixture(%{user: user, media_urls: [media_url]})

      {:ok, _post} =
        Messages.update_message_metadata(post, %{
          media_metadata: %{
            "attachments" => [
              %{
                "id" => "image-1",
                "url" => media_url,
                "mime_type" => "image/png",
                "byte_size" => 1234
              }
            ],
            "preserved" => true
          }
        })

      conn =
        conn
        |> assign(:current_user, user)
        |> MediaAttachmentController.update(%{
          "media_url" => media_url,
          "description" => "Diagram preview",
          "focus" => "0.25,-0.5"
        })

      assert %{
               "description" => "Diagram preview",
               "meta" => %{"focus" => %{"x" => 0.25, "y" => -0.5}},
               "type" => "image",
               "url" => ^media_url
             } = json_response(conn, 200)

      updated = Repo.get!(Message, post.id)

      assert updated.media_metadata["alt_texts"] == %{"0" => "Diagram preview"}
      assert updated.media_metadata["preserved"] == true

      assert [
               %{
                 "alt_text" => "Diagram preview",
                 "byte_size" => 1234,
                 "focus" => %{"x" => 0.25, "y" => -0.5},
                 "mime_type" => "image/png",
                 "url" => ^media_url
               }
             ] = updated.media_metadata["attachments"]
    end

    test "updates by stored attachment id", %{conn: conn} do
      user = user_fixture()
      media_url = "/uploads/timeline-attachments/#{user.id}/image.jpg"
      post = media_post_fixture(%{user: user, media_urls: [media_url]})

      {:ok, _post} =
        Messages.update_message_metadata(post, %{
          media_metadata: %{
            "attachments" => [
              %{"id" => "attachment-local-id", "url" => media_url, "mime_type" => "image/jpeg"}
            ]
          }
        })

      conn =
        conn
        |> assign(:current_user, user)
        |> MediaAttachmentController.update(%{
          "id" => "attachment-local-id",
          "text" => "Stored id description"
        })

      assert %{"description" => "Stored id description"} = json_response(conn, 200)

      updated = Repo.get!(Message, post.id)
      assert get_in(updated.media_metadata, ["alt_texts", "0"]) == "Stored id description"
    end

    test "does not update another user's attachment", %{conn: conn} do
      owner = user_fixture()
      viewer = user_fixture()
      media_url = "/uploads/timeline-attachments/#{owner.id}/image.png"
      post = media_post_fixture(%{user: owner, media_urls: [media_url]})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> MediaAttachmentController.update(%{
          "media_url" => media_url,
          "description" => "Nope"
        })

      assert %{"error" => "media attachment not found"} = json_response(conn, 404)

      updated = Repo.get!(Message, post.id)
      refute get_in(updated.media_metadata || %{}, ["alt_texts", "0"])
    end

    test "rejects empty metadata updates", %{conn: conn} do
      user = user_fixture()
      media_url = "/uploads/timeline-attachments/#{user.id}/image.png"
      _post = media_post_fixture(%{user: user, media_urls: [media_url]})

      conn =
        conn
        |> assign(:current_user, user)
        |> MediaAttachmentController.update(%{"media_url" => media_url})

      assert %{"error" => "media metadata cannot be empty"} = json_response(conn, 422)
    end
  end

  defp upload_fixture(tmp_dir, filename, content_type, content) do
    path = Path.join(tmp_dir, "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, content)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp png_bytes do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0>>
  end
end
