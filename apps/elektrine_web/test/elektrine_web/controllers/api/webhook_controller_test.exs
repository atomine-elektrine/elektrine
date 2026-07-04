defmodule ArblargWeb.API.WebhookControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatWebhook
  alias Elektrine.Repo
  alias ElektrineWeb.Plugs.APIAuth

  setup do
    owner = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()

    {:ok, server} = Messaging.create_server(owner.id, %{name: "hook-api", is_public: true})
    {:ok, _member} = Messaging.join_server(server.id, member.id)
    [channel | _] = server.channels

    {:ok, owner_token} = APIAuth.generate_token(owner.id)
    {:ok, member_token} = APIAuth.generate_token(member.id)

    %{
      owner: owner,
      member: member,
      channel: channel,
      owner_token: owner_token,
      member_token: member_token
    }
  end

  defp auth_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp create_webhook(conn, channel, token, attrs \\ %{}) do
    conn
    |> auth_conn(token)
    |> post("/api/conversations/#{channel.id}/webhooks", Map.merge(%{name: "CI Bot"}, attrs))
  end

  describe "webhook management" do
    test "owner can create a webhook and receives the token once", ctx do
      conn = create_webhook(ctx.conn, ctx.channel, ctx.owner_token)

      response = json_response(conn, 201)
      assert response["webhook"]["name"] == "CI Bot"
      assert response["webhook"]["active"] == true
      assert String.starts_with?(response["webhook"]["token"], "ewh_")

      # Stored hashed; the plaintext token never appears in later reads.
      stored = Repo.get(ChatWebhook, response["webhook"]["id"])
      assert stored.token_hash == ChatWebhook.hash_token(response["webhook"]["token"])

      list_conn =
        ctx.conn
        |> auth_conn(ctx.owner_token)
        |> get("/api/conversations/#{ctx.channel.id}/webhooks")

      [listed] = json_response(list_conn, 200)["webhooks"]
      refute Map.has_key?(listed, "token")
    end

    test "regular members cannot manage webhooks", ctx do
      conn = create_webhook(ctx.conn, ctx.channel, ctx.member_token)
      assert json_response(conn, 403)

      list_conn =
        ctx.conn
        |> auth_conn(ctx.member_token)
        |> get("/api/conversations/#{ctx.channel.id}/webhooks")

      assert json_response(list_conn, 403)
    end

    test "requires authentication", ctx do
      conn = post(ctx.conn, "/api/conversations/#{ctx.channel.id}/webhooks", %{name: "Nope"})
      assert conn.status == 401
    end

    test "update, rotate, deactivate, delete", ctx do
      created =
        create_webhook(ctx.conn, ctx.channel, ctx.owner_token)
        |> json_response(201)
        |> Map.fetch!("webhook")

      update_conn =
        ctx.conn
        |> auth_conn(ctx.owner_token)
        |> put("/api/webhooks/#{created["id"]}", %{name: "Renamed"})

      assert json_response(update_conn, 200)["webhook"]["name"] == "Renamed"

      rotate_conn =
        ctx.conn
        |> auth_conn(ctx.owner_token)
        |> post("/api/webhooks/#{created["id"]}/rotate")

      rotated = json_response(rotate_conn, 200)["webhook"]
      assert String.starts_with?(rotated["token"], "ewh_")
      refute rotated["token"] == created["token"]

      deactivate_conn =
        ctx.conn
        |> auth_conn(ctx.owner_token)
        |> post("/api/webhooks/#{created["id"]}/deactivate")

      assert json_response(deactivate_conn, 200)["webhook"]["active"] == false

      delete_conn =
        ctx.conn
        |> auth_conn(ctx.owner_token)
        |> delete("/api/webhooks/#{created["id"]}")

      assert json_response(delete_conn, 200)["success"] == true
      refute Repo.get(ChatWebhook, created["id"])
    end
  end

  describe "POST /api/webhooks/:id/:token (execute)" do
    setup ctx do
      webhook =
        create_webhook(ctx.conn, ctx.channel, ctx.owner_token, %{
          avatar_url: "https://i.imgur.com/bot.png"
        })
        |> json_response(201)
        |> Map.fetch!("webhook")

      %{webhook: webhook}
    end

    test "posts a message without any session auth", ctx do
      conn =
        post(ctx.conn, "/api/webhooks/#{ctx.webhook["id"]}/#{ctx.webhook["token"]}", %{
          content: "deploy finished"
        })

      response = json_response(conn, 201)
      assert response["conversation_id"] == ctx.channel.id

      message = Messaging.get_chat_message(response["id"])
      assert message.content == "deploy finished"
      assert message.sender_id == nil
      assert message.webhook_id == ctx.webhook["id"]
    end

    test "applies username/avatar overrides and serializes bot flags", ctx do
      exec_conn =
        post(ctx.conn, "/api/webhooks/#{ctx.webhook["id"]}/#{ctx.webhook["token"]}", %{
          content: "with overrides",
          username: "Release Notes",
          avatar_url: "https://i.imgur.com/other.png"
        })

      assert json_response(exec_conn, 201)

      list_conn =
        ctx.conn
        |> auth_conn(ctx.member_token)
        |> get("/api/conversations/#{ctx.channel.id}/messages")

      messages = json_response(list_conn, 200)["messages"]
      message = Enum.find(messages, &(&1["content"] == "with overrides"))

      assert message["webhook_id"] == ctx.webhook["id"]
      assert message["sender"]["username"] == "Release Notes"
      assert message["sender"]["avatar"] == "https://i.imgur.com/other.png"
      assert message["sender"]["is_bot"] == true
      assert message["sender"]["webhook"] == true
    end

    test "returns 404 for bad token or unknown id", ctx do
      conn = post(ctx.conn, "/api/webhooks/#{ctx.webhook["id"]}/ewh_bad-token", %{content: "hi"})
      assert json_response(conn, 404)

      conn =
        post(ctx.conn, "/api/webhooks/999999999/#{ctx.webhook["token"]}", %{content: "hi"})

      assert json_response(conn, 404)
    end

    test "rejects inactive webhooks", ctx do
      ctx.conn
      |> auth_conn(ctx.owner_token)
      |> post("/api/webhooks/#{ctx.webhook["id"]}/deactivate")

      conn =
        post(ctx.conn, "/api/webhooks/#{ctx.webhook["id"]}/#{ctx.webhook["token"]}", %{
          content: "hi"
        })

      assert json_response(conn, 403)
    end

    test "rejects empty content", ctx do
      conn = post(ctx.conn, "/api/webhooks/#{ctx.webhook["id"]}/#{ctx.webhook["token"]}", %{})
      assert json_response(conn, 422)
    end

    test "returns 429 when rate limited", ctx do
      for _ <- 1..30 do
        Elektrine.Messaging.RateLimiter.record_webhook_execution(ctx.webhook["id"])
      end

      conn =
        post(ctx.conn, "/api/webhooks/#{ctx.webhook["id"]}/#{ctx.webhook["token"]}", %{
          content: "hi"
        })

      assert json_response(conn, 429)
    end
  end

  describe "bot user serialization" do
    test "bot-authored messages expose is_bot in the message API", ctx do
      bot = AccountsFixtures.user_fixture()
      {:ok, bot} = bot |> Ecto.Changeset.change(is_bot: true) |> Repo.update()
      {:ok, _} = Messaging.join_server(ctx.channel.server_id, bot.id)

      {:ok, message} = Messaging.create_chat_text_message(ctx.channel.id, bot.id, "beep boop")

      list_conn =
        ctx.conn
        |> auth_conn(ctx.member_token)
        |> get("/api/conversations/#{ctx.channel.id}/messages")

      messages = json_response(list_conn, 200)["messages"]
      serialized = Enum.find(messages, &(&1["id"] == message.id))

      assert serialized["sender"]["is_bot"] == true
      assert serialized["sender"]["webhook"] == false
    end
  end
end
