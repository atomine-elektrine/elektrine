defmodule ElektrineWeb.API.MCPControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.EmailFixtures

  alias Elektrine.Developer
  alias Elektrine.Email
  alias ElektrineWeb.Plugs.APIAuth

  defp token_for(user, scopes) do
    {:ok, token} =
      Developer.create_api_token(user.id, %{
        name: "MCP test token",
        scopes: scopes
      })

    token.token
  end

  defp mcp_post(conn, token, payload) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/ext/v1/mcp", Jason.encode!(payload))
  end

  test "initializes an MCP session", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-11-25"}
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "protocolVersion" => "2025-11-25",
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{"name" => "elektrine", "version" => "ext-v1"}
             }
           } = json_response(conn, 200)

    assert get_resp_header(conn, "mcp-protocol-version") == ["2025-11-25"]
  end

  test "negotiates unsupported initialize versions to the latest server version", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => "version",
        "method" => "initialize",
        "params" => %{"protocolVersion" => "1999-01-01"}
      })

    assert get_in(json_response(conn, 200), ["result", "protocolVersion"]) == "2025-11-25"
  end

  test "rejects legacy account API tokens", %{conn: conn} do
    user = user_fixture()
    {:ok, legacy_token} = APIAuth.generate_token(user.id)

    conn =
      mcp_post(conn, legacy_token, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize"
      })

    assert json_response(conn, 401)["error"] == %{
             "code" => "invalid_token_format",
             "message" => "Invalid token format"
           }
  end

  test "lists only tools allowed by the PAT scopes", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:kairo"])

    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => "tools",
        "method" => "tools/list"
      })

    tool_names =
      conn
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Enum.map(& &1["name"])

    assert "elektrine.capabilities" in tool_names
    assert "kairo.projects.list" in tool_names
    assert "kairo.sources.list" in tool_names
    refute "account.me" in tool_names
    refute "nerve.entries.list" in tool_names
  end

  test "lists email tools for read email scopes", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:email"])

    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => "email-tools",
        "method" => "tools/list"
      })

    tool_names =
      conn
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Enum.map(& &1["name"])

    assert "email.messages.list" in tool_names
    assert "email.messages.search" in tool_names
    assert "email.messages.get" in tool_names
    refute "email.messages.send" in tool_names
    refute "email.messages.update" in tool_names
  end

  test "calls email list, get, and update tools", %{conn: conn} do
    user = user_fixture()
    mailbox = mailbox_fixture(%{user_id: user.id, email: "mcpemail#{user.id}@example.com"})

    message =
      message_fixture(%{
        mailbox_id: mailbox.id,
        to: mailbox.email,
        subject: "MCP email subject",
        text_body: "MCP email body",
        read: false
      })

    token = token_for(user, ["read:email", "write:email"])

    list_conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => "email-list",
        "method" => "tools/call",
        "params" => %{
          "name" => "email.messages.list",
          "arguments" => %{"folder" => "all", "limit" => 5}
        }
      })

    assert [%{"subject" => "MCP email subject"} | _] =
             get_in(json_response(list_conn, 200), [
               "result",
               "structuredContent",
               "messages"
             ])

    get_conn =
      build_conn()
      |> mcp_post(token, %{
        "jsonrpc" => "2.0",
        "id" => "email-get",
        "method" => "tools/call",
        "params" => %{
          "name" => "email.messages.get",
          "arguments" => %{"id" => message.id}
        }
      })

    assert get_in(json_response(get_conn, 200), [
             "result",
             "structuredContent",
             "message",
             "text_body"
           ]) == "MCP email body"

    update_conn =
      build_conn()
      |> mcp_post(token, %{
        "jsonrpc" => "2.0",
        "id" => "email-update",
        "method" => "tools/call",
        "params" => %{
          "name" => "email.messages.update",
          "arguments" => %{"id" => message.id, "read" => true}
        }
      })

    assert get_in(json_response(update_conn, 200), [
             "result",
             "structuredContent",
             "email",
             "read"
           ]) == true

    assert {:ok, updated_message} = Email.get_user_message(message.id, user.id)
    assert updated_message.read == true
  end

  test "calls a Kairo create-source tool with write scope", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:kairo", "write:kairo"])

    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "kairo.sources.create",
          "arguments" => %{
            "source_type" => "markdown",
            "title" => "MCP note",
            "content" => "Created through MCP"
          }
        }
      })

    response = json_response(conn, 200)
    assert get_in(response, ["result", "structuredContent", "source", "title"]) == "MCP note"

    assert get_in(response, ["result", "structuredContent", "source", "content"]) ==
             "Created through MCP"

    assert [%{"type" => "text", "text" => text}] = get_in(response, ["result", "content"])
    assert text =~ "MCP note"
  end

  test "returns a tool error when scopes are insufficient", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:kairo"])

    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "nerve.entries.list",
          "arguments" => %{}
        }
      })

    response = json_response(conn, 200)
    assert get_in(response, ["result", "isError"]) == true

    assert response |> get_in(["result", "content"]) |> List.first() |> Map.get("text") =~
             "read:nerve"
  end

  test "returns 202 for notifications", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    assert response(conn, 202) == ""
  end

  test "returns 202 for client JSON-RPC responses", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => "client-response",
        "result" => %{}
      })

    assert response(conn, 202) == ""
  end

  test "rejects JSON-RPC batches for Streamable HTTP", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      mcp_post(conn, token, [
        %{"jsonrpc" => "2.0", "id" => "a", "method" => "initialize"},
        %{"jsonrpc" => "2.0", "id" => "b", "method" => "tools/list"}
      ])

    assert %{
             "jsonrpc" => "2.0",
             "error" => %{"code" => -32_600, "message" => "Invalid Request"}
           } = json_response(conn, 400)
  end

  test "rejects requests missing the MCP Accept values", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/ext/v1/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )

    assert %{"error" => %{"message" => "Invalid Request"}} = json_response(conn, 406)
  end

  test "rejects unsupported protocol version headers", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "1999-01-01")
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/ext/v1/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )

    assert %{"error" => %{"data" => %{"protocolVersion" => "1999-01-01"}}} =
             json_response(conn, 400)
  end

  test "rejects browser requests from a different origin", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("origin", "https://evil.example")
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/ext/v1/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )

    assert %{
             "error" => %{"data" => %{"reason" => "Origin is not allowed for this MCP endpoint."}}
           } =
             json_response(conn, 403)
  end

  test "rejects invalid JSON-RPC envelopes", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      mcp_post(conn, token, %{
        "id" => "bad",
        "method" => "initialize"
      })

    assert %{"id" => "bad", "error" => %{"code" => -32_600}} = json_response(conn, 400)
  end

  test "GET stream endpoint returns 405 when SSE is not offered", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/api/ext/v1/mcp")

    assert response(conn, 405) == ""
    assert get_resp_header(conn, "allow") == ["POST, GET"]
  end

  test "DELETE session endpoint returns 405 for stateless MCP", %{conn: conn} do
    user = user_fixture()
    token = token_for(user, ["read:account"])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("mcp-session-id", "unused")
      |> delete(~p"/api/ext/v1/mcp")

    assert response(conn, 405) == ""
    assert get_resp_header(conn, "allow") == ["POST, GET"]
  end
end
