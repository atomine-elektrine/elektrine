defmodule ElektrineWeb.API.ExtV1ControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.EmailFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Developer
  alias Elektrine.Email
  alias Elektrine.Email.Contacts
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Repo
  alias Elektrine.Social

  describe "PAT auth + versioned external API" do
    test "returns standardized missing token error", %{conn: conn} do
      conn = get(conn, "/api/ext/v1/search", %{"q" => "hello"})

      assert %{"error" => error, "meta" => _meta} = json_response(conn, 401)
      assert error["code"] == "missing_token"
      assert error["message"] == "API token required"
    end

    test "search endpoint returns data and pagination meta", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["read:account"])

      conn = get(conn, "/api/ext/v1/search", %{"q" => "hello", "limit" => "5"})

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert data["query"] == "hello"
      assert is_list(data["results"])
      assert meta["pagination"]["limit"] == 5
    end

    test "search only returns result types allowed by token scopes", %{conn: conn} do
      user = user_fixture()

      account_conn = with_pat(conn, user.id, ["read:account"])
      account_conn = get(account_conn, "/api/ext/v1/search", %{"q" => "profile", "limit" => "5"})

      assert %{"data" => %{"results" => account_results}} = json_response(account_conn, 200)
      assert Enum.any?(account_results, &(&1["type"] == "settings"))

      email_conn = with_pat(conn, user.id, ["read:email"])
      email_conn = get(email_conn, "/api/ext/v1/search", %{"q" => "profile", "limit" => "5"})

      assert %{"data" => %{"results" => email_results}} = json_response(email_conn, 200)
      refute Enum.any?(email_results, &(&1["type"] == "settings"))
    end

    test "capabilities endpoint exposes token presets and allowed endpoints", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["webhook"])

      conn = get(conn, "/api/ext/v1/capabilities")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["api_version"] == "ext-v1"
      assert is_list(data["capabilities"]["token_presets"])
      assert Enum.any?(data["capabilities"]["endpoints"], &(&1["path"] == "/api/ext/v1/webhooks"))
      refute Enum.any?(data["capabilities"]["endpoints"], &(&1["path"] == "/api/ext/v1/me"))
    end

    test "me endpoint returns token metadata for account-scoped tokens", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["read:account"])

      conn = get(conn, "/api/ext/v1/me")

      assert %{"data" => %{"user" => me_user, "token" => token}} = json_response(conn, 200)
      assert me_user["id"] == user.id
      assert token["name"] =~ "test-token-"
      assert token["scopes"] == ["read:account"]
    end

    test "capabilities only advertises endpoints allowed by read scopes", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["read:chat"])

      conn = get(conn, "/api/ext/v1/capabilities")

      assert %{"data" => %{"capabilities" => %{"endpoints" => endpoints}}} =
               json_response(conn, 200)

      assert Enum.any?(endpoints, &(&1["path"] == "/api/ext/v1/chat/conversations"))
      refute Enum.any?(endpoints, &(&1["path"] == "/api/ext/v1/email/messages"))
    end

    test "email endpoints only expose messages from owned mailboxes", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      {:ok, other_mailbox} = Email.ensure_user_has_mailbox(other_user)

      own_message =
        message_fixture(%{
          mailbox_id: mailbox.id,
          to: mailbox.email,
          subject: "Owned PAT message"
        })

      other_message =
        message_fixture(%{
          mailbox_id: other_mailbox.id,
          to: other_mailbox.email,
          subject: "Other mailbox message"
        })

      conn = with_pat(conn, user.id, ["read:email"])

      list_conn = get(conn, "/api/ext/v1/email/messages")

      assert %{"data" => %{"messages" => messages}} = json_response(list_conn, 200)
      assert Enum.any?(messages, &(&1["id"] == own_message.id))
      refute Enum.any?(messages, &(&1["id"] == other_message.id))

      show_conn = get(conn, "/api/ext/v1/email/messages/#{own_message.id}")
      assert %{"data" => %{"message" => message}} = json_response(show_conn, 200)
      assert message["subject"] == "Owned PAT message"

      other_conn = get(conn, "/api/ext/v1/email/messages/#{other_message.id}")
      assert %{"error" => error} = json_response(other_conn, 404)
      assert error["code"] == "not_found"
    end

    test "chat endpoints only expose member conversations", %{conn: conn} do
      user = user_fixture()
      friend = user_fixture()
      stranger = user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(user.id, friend.id)
      {:ok, other_conversation} = Messaging.create_dm_conversation(friend.id, stranger.id)

      Repo.insert!(
        ChatMessage.changeset(%ChatMessage{}, %{
          conversation_id: conversation.id,
          sender_id: user.id,
          content: "hello from pat chat",
          message_type: "text"
        })
      )

      Repo.insert!(
        ChatMessage.changeset(%ChatMessage{}, %{
          conversation_id: other_conversation.id,
          sender_id: friend.id,
          content: "hidden from pat chat",
          message_type: "text"
        })
      )

      conn = with_pat(conn, user.id, ["read:chat"])

      list_conn = get(conn, "/api/ext/v1/chat/conversations")

      assert %{"data" => %{"conversations" => conversations}} = json_response(list_conn, 200)
      assert Enum.any?(conversations, &(&1["id"] == conversation.id))
      refute Enum.any?(conversations, &(&1["id"] == other_conversation.id))

      show_conn = get(conn, "/api/ext/v1/chat/conversations/#{conversation.id}")

      assert %{"data" => %{"conversation" => shown_conversation, "messages" => messages}} =
               json_response(show_conn, 200)

      assert shown_conversation["id"] == conversation.id
      assert Enum.any?(messages, &(&1["content"] == "hello from pat chat"))

      hidden_conn = get(conn, "/api/ext/v1/chat/conversations/#{other_conversation.id}/messages")
      assert %{"error" => error} = json_response(hidden_conn, 404)
      assert error["code"] == "not_found"
    end

    test "social endpoints respect post visibility", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      public_post = post_fixture(user: author, content: "Public PAT post", visibility: "public")

      followers_post =
        post_fixture(user: author, content: "Followers PAT post", visibility: "followers")

      conn = with_pat(conn, viewer.id, ["read:social"])

      public_conn = get(conn, "/api/ext/v1/social/posts/#{public_post.id}")
      assert %{"data" => %{"post" => post}} = json_response(public_conn, 200)
      assert post["content"] == "Public PAT post"

      hidden_conn = get(conn, "/api/ext/v1/social/posts/#{followers_post.id}")
      assert %{"error" => hidden_error} = json_response(hidden_conn, 404)
      assert hidden_error["code"] == "not_found"

      assert {:ok, _follow} = Social.follow_user(viewer.id, author.id)

      allowed_conn = get(conn, "/api/ext/v1/social/posts/#{followers_post.id}")
      assert %{"data" => %{"post" => visible_post}} = json_response(allowed_conn, 200)
      assert visible_post["content"] == "Followers PAT post"

      user_posts_conn = get(conn, "/api/ext/v1/social/users/#{author.id}/posts")
      assert %{"data" => %{"posts" => posts}} = json_response(user_posts_conn, 200)
      assert Enum.any?(posts, &(&1["id"] == followers_post.id))
    end

    test "contacts endpoints return address book contacts", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()

      {:ok, contact} =
        Contacts.create_contact(%{
          user_id: user.id,
          name: "Ada Lovelace",
          email: "ada@example.com"
        })

      {:ok, other_contact} =
        Contacts.create_contact(%{
          user_id: other_user.id,
          name: "Grace Hopper",
          email: "grace@example.com"
        })

      conn = with_pat(conn, user.id, ["read:contacts"])

      list_conn = get(conn, "/api/ext/v1/contacts")

      assert %{"data" => %{"contacts" => contacts}} = json_response(list_conn, 200)
      assert Enum.any?(contacts, &(&1["id"] == contact.id))
      refute Enum.any?(contacts, &(&1["id"] == other_contact.id))

      show_conn = get(conn, "/api/ext/v1/contacts/#{contact.id}")
      assert %{"data" => %{"contact" => shown_contact}} = json_response(show_conn, 200)
      assert shown_contact["email"] == "ada@example.com"

      hidden_conn = get(conn, "/api/ext/v1/contacts/#{other_contact.id}")
      assert %{"error" => error} = json_response(hidden_conn, 404)
      assert error["code"] == "not_found"
    end

    test "export endpoints require export scope", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["read:account"])

      conn = get(conn, "/api/ext/v1/exports")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "insufficient_scope"
    end

    test "password manager endpoints accept dedicated vault scopes", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["read:vault"])

      conn = get(conn, "/api/ext/v1/password-manager/entries")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["vault_configured"] == false
      assert data["entries"] == []
    end

    test "webhook endpoints work with webhook scope", %{conn: conn} do
      user = user_fixture()
      conn = with_pat(conn, user.id, ["webhook"])

      create_payload = %{
        "name" => "API Hook",
        "url" => "https://example.com/webhook",
        "events" => ["post.created"]
      }

      created_conn = post(conn, "/api/ext/v1/webhooks", create_payload)

      assert %{"data" => created_data} = json_response(created_conn, 201)
      assert %{"id" => webhook_id, "name" => "API Hook"} = created_data["webhook"]
      assert is_binary(created_data["secret"])

      show_conn = get(conn, "/api/ext/v1/webhooks/#{webhook_id}")
      assert %{"data" => show_data} = json_response(show_conn, 200)
      assert show_data["webhook"]["id"] == webhook_id

      replay_conn = post(conn, "/api/ext/v1/webhooks/#{webhook_id}/deliveries/999999/replay")
      assert %{"error" => replay_error} = json_response(replay_conn, 404)
      assert replay_error["code"] == "not_found"

      delete_conn = delete(conn, "/api/ext/v1/webhooks/#{webhook_id}")
      assert %{"data" => %{"message" => "Webhook deleted"}} = json_response(delete_conn, 200)
    end
  end

  defp with_pat(conn, user_id, scopes) do
    {:ok, token} =
      Developer.create_api_token(user_id, %{
        name: "test-token-#{System.unique_integer([:positive])}",
        scopes: scopes
      })

    put_req_header(conn, "authorization", "Bearer #{token.token}")
  end
end
