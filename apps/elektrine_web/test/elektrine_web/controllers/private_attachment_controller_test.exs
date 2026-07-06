defmodule ElektrineWeb.PrivateAttachmentControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging.{ChatConversation, ChatConversationMember, ChatMessage}
  alias Elektrine.Repo
  alias Elektrine.Uploads

  setup do
    previous_uploads = Application.get_env(:elektrine, :uploads)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "elektrine-private-attachments-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "chat-attachments"))
    File.mkdir_p!(Path.join(tmp_dir, "kairo-sources"))

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

  test "serves local DM attachments to active conversation members", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    user = AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    filepath = Path.join([tmp_dir, "chat-attachments", "private.txt"])
    File.write!(filepath, "secret payload")

    url = Uploads.attachment_url("chat-attachments/private.txt", %{type: "dm"})
    add_message_attachment_for_member(user, "chat-attachments/private.txt")

    assert String.starts_with?(url, "/api/private-attachments/")

    conn = get(conn, url)

    assert response(conn, 200) == "secret payload"
    assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-disposition") == ["inline; filename=\"private.txt\""]
  end

  test "forces download for active content types", %{conn: conn, tmp_dir: tmp_dir} do
    user = AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    filepath = Path.join([tmp_dir, "chat-attachments", "private.html"])
    File.write!(filepath, "<script>alert('xss')</script>")

    url = Uploads.attachment_url("chat-attachments/private.html", %{type: "dm"})
    add_message_attachment_for_member(user, "chat-attachments/private.html")

    conn = get(conn, url)

    assert response(conn, 200) == "<script>alert('xss')</script>"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"private.html\""
           ]
  end

  test "rejects invalid private attachment tokens", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> get("/api/private-attachments/invalid-token")

    assert response(conn, 404) == "Not found"
  end

  test "rejects valid attachment tokens for non-members", %{conn: conn, tmp_dir: tmp_dir} do
    member = AccountsFixtures.user_fixture()
    non_member = AccountsFixtures.user_fixture()
    filepath = Path.join([tmp_dir, "chat-attachments", "member-only.txt"])
    File.write!(filepath, "secret payload")

    url = Uploads.attachment_url("chat-attachments/member-only.txt", %{type: "dm"})
    add_message_attachment_for_member(member, "chat-attachments/member-only.txt")

    conn =
      conn
      |> log_in_user(non_member)
      |> get(url)

    assert response(conn, 404) == "Not found"
  end

  test "serves Kairo source files to the owning user", %{conn: conn, tmp_dir: tmp_dir} do
    user = AccountsFixtures.user_fixture()
    key = "kairo-sources/source.txt"
    filepath = Path.join([tmp_dir, "kairo-sources", "source.txt"])
    File.write!(filepath, "kairo payload")

    {:ok, _source} =
      Kairo.create_source(user, %{
        "source_type" => "file",
        "title" => "source.txt",
        "metadata" => %{"key" => key, "content_type" => "text/plain"}
      })

    url = Uploads.attachment_url(key, %{visibility: "private"})

    conn =
      conn
      |> log_in_user(user)
      |> get(url)

    assert response(conn, 200) == "kairo payload"
    assert get_resp_header(conn, "content-disposition") == ["inline; filename=\"source.txt\""]
  end

  test "rejects Kairo source files for other users", %{conn: conn, tmp_dir: tmp_dir} do
    owner = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    key = "kairo-sources/owner-only.txt"
    filepath = Path.join([tmp_dir, "kairo-sources", "owner-only.txt"])
    File.write!(filepath, "owner only")

    {:ok, _source} =
      Kairo.create_source(owner, %{
        "source_type" => "file",
        "title" => "owner-only.txt",
        "metadata" => %{"key" => key, "content_type" => "text/plain"}
      })

    url = Uploads.attachment_url(key, %{visibility: "private"})

    conn =
      conn
      |> log_in_user(other_user)
      |> get(url)

    assert response(conn, 404) == "Not found"
  end

  test "rejects local attachment symlinks that point outside uploads", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    user = AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)

    outside_path =
      Path.join(System.tmp_dir!(), "elektrine-private-attachment-leak-#{System.unique_integer()}")

    File.write!(outside_path, "outside secret")
    on_exit(fn -> File.rm(outside_path) end)

    link_path = Path.join([tmp_dir, "chat-attachments", "leak.txt"])
    :ok = File.ln_s(outside_path, link_path)

    url = Uploads.attachment_url("chat-attachments/leak.txt", %{type: "dm"})
    add_message_attachment_for_member(user, "chat-attachments/leak.txt")

    conn = get(conn, url)

    assert response(conn, 404) == "Not found"
  end

  defp add_message_attachment_for_member(user, key) do
    conversation = Repo.insert!(%ChatConversation{type: "dm"})

    Repo.insert!(%ChatConversationMember{
      conversation_id: conversation.id,
      user_id: user.id,
      role: "member",
      joined_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    Repo.insert!(%ChatMessage{
      conversation_id: conversation.id,
      sender_id: user.id,
      content: nil,
      message_type: "file",
      media_urls: [key]
    })
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
