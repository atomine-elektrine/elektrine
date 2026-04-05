defmodule ElektrineWeb.PrivateAttachmentControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.Uploads

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "elektrine-private-attachments-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "chat-attachments"))

    Application.put_env(:elektrine, :uploads,
      adapter: :local,
      uploads_dir: tmp_dir
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :uploads, previous_uploads)
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "serves local DM attachments through a signed URL", %{conn: conn, tmp_dir: tmp_dir} do
    filepath = Path.join([tmp_dir, "chat-attachments", "private.txt"])
    File.write!(filepath, "secret payload")

    url = Uploads.attachment_url("chat-attachments/private.txt", %{type: "dm"})

    assert String.starts_with?(url, "/api/private-attachments/")

    conn = get(conn, url)

    assert response(conn, 200) == "secret payload"
    assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-disposition") == ["inline; filename=\"private.txt\""]
  end

  test "forces download for active content types", %{conn: conn, tmp_dir: tmp_dir} do
    filepath = Path.join([tmp_dir, "chat-attachments", "private.html"])
    File.write!(filepath, "<script>alert('xss')</script>")

    url = Uploads.attachment_url("chat-attachments/private.html", %{type: "dm"})

    conn = get(conn, url)

    assert response(conn, 200) == "<script>alert('xss')</script>"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"private.html\""
           ]
  end

  test "rejects invalid private attachment tokens", %{conn: conn} do
    conn = get(conn, "/api/private-attachments/invalid-token")

    assert response(conn, 404) == "Not found"
  end
end
