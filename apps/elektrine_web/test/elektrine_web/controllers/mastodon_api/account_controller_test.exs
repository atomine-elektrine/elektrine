defmodule ElektrineWeb.MastodonAPI.AccountControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.OAuth

  setup %{conn: conn} do
    user = user_fixture()
    target = user_fixture()

    {:ok, app} =
      OAuth.create_app(%{
        client_name: "test-app-#{System.unique_integer([:positive])}",
        redirect_uris: "https://client.example/callback",
        scopes: ["read", "write", "write:mutes"]
      })

    valid_until =
      DateTime.utc_now()
      |> DateTime.add(3600, :second)
      |> DateTime.truncate(:second)

    {:ok, token} =
      OAuth.create_token(app, user, %{
        scopes: ["read", "write", "write:mutes"],
        valid_until: valid_until
      })

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token.token}")

    %{conn: conn, user: user, target: target}
  end

  describe "POST /api/v1/accounts/:id/mute" do
    test "mutes target account", %{conn: conn, target: target} do
      conn = post(conn, ~p"/api/v1/accounts/#{target.id}/mute")
      body = json_response(conn, 200)

      assert body["id"] == to_string(target.id)
      assert body["muting"] == true
      assert body["muting_notifications"] == false
    end

    test "supports muting notifications", %{conn: conn, target: target} do
      conn = post(conn, ~p"/api/v1/accounts/#{target.id}/mute", %{"notifications" => "true"})
      body = json_response(conn, 200)

      assert body["muting"] == true
      assert body["muting_notifications"] == true
    end

    test "cannot mute yourself", %{conn: conn, user: user} do
      conn = post(conn, ~p"/api/v1/accounts/#{user.id}/mute")
      body = json_response(conn, 422)
      assert body["error"] == "Cannot mute yourself"
    end
  end

  describe "POST /api/v1/accounts/:id/unmute" do
    test "unmutes target account", %{conn: conn, target: target} do
      conn = post(conn, ~p"/api/v1/accounts/#{target.id}/mute")
      assert json_response(conn, 200)["muting"] == true

      conn = post(conn, ~p"/api/v1/accounts/#{target.id}/unmute")
      body = json_response(conn, 200)

      assert body["muting"] == false
      assert body["muting_notifications"] == false
    end

    test "is idempotent when target is not muted", %{conn: conn, target: target} do
      conn = post(conn, ~p"/api/v1/accounts/#{target.id}/unmute")
      body = json_response(conn, 200)

      assert body["muting"] == false
      assert body["muting_notifications"] == false
    end
  end

  describe "GET /api/v1/accounts/lookup" do
    test "renders an account without legacy user fields", %{conn: conn, target: target} do
      conn = get(conn, ~p"/api/v1/accounts/lookup", %{acct: target.username})
      body = json_response(conn, 200)

      assert body["id"] == to_string(target.id)
      assert body["username"] == target.username
      assert body["note"] == ""
      assert is_boolean(body["locked"])
    end
  end

  describe "GET /api/v1/accounts/:id/statuses" do
    test "renders nested account data without legacy user fields", %{conn: conn, target: target} do
      post = post_fixture(user: target)

      conn = get(conn, ~p"/api/v1/accounts/#{target.id}/statuses")
      body = json_response(conn, 200)

      assert [%{"id" => post_id, "account" => %{"id" => account_id}}] = body
      assert post_id == to_string(post.id)
      assert account_id == to_string(target.id)
    end
  end
end
