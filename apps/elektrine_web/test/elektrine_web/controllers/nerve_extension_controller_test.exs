defmodule ElektrineWeb.NerveExtensionControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.Developer

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "nervedownload#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    %{user: user}
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

  test "packages the extension files in application priv" do
    priv_manifest = Application.app_dir(:elektrine_web, "priv/nerve-extension/manifest.json")

    assert File.exists?(priv_manifest)
    assert File.read!(priv_manifest) =~ "\"name\": \"Elektrine Nerve\""
  end

  test "downloads the chromium extension archive", %{conn: conn, user: user} do
    conn = get(log_in_user(conn, user), ~p"/account/nerve/extension/chromium/download")

    assert get_resp_header(conn, "content-type") == ["application/zip; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"elektrine-nerve-extension-chromium.zip\""
           ]

    assert {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    assert length(files) > 5

    assert {~c"manifest.json", manifest} =
             Enum.find(files, fn {name, _contents} -> name == ~c"manifest.json" end)

    assert manifest =~ "\"name\": \"Elektrine Nerve\""
    assert Enum.any?(files, fn {name, _contents} -> name == ~c"content.js" end)
    assert Enum.any?(files, fn {name, _contents} -> name == ~c"background.js" end)
  end

  test "downloads the firefox extension archive", %{conn: conn, user: user} do
    conn = get(log_in_user(conn, user), ~p"/account/nerve/extension/firefox/download")

    assert get_resp_header(conn, "content-type") == ["application/x-xpinstall; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"elektrine-nerve-extension-firefox.xpi\""
           ]
  end

  test "shows extension connection approval for safe callback URLs", %{conn: conn, user: user} do
    conn =
      get(log_in_user(conn, user), ~p"/account/nerve/extension/connect", %{
        "return_to" => "https://abc123.chromiumapp.org/nerve",
        "state" => "state-123"
      })

    assert html_response(conn, 200) =~ "Connect Browser Extension"
    assert conn.resp_body =~ "state-123"
  end

  test "rejects unsafe extension callback URLs", %{conn: conn, user: user} do
    conn =
      get(log_in_user(conn, user), ~p"/account/nerve/extension/connect", %{
        "return_to" => "https://evil.example/callback"
      })

    assert text_response(conn, 400) =~ "Invalid extension return URL"
  end

  test "authorizes extension connection with a scoped Nerve token", %{conn: conn, user: user} do
    return_to = "https://abc123.chromiumapp.org/nerve"

    conn =
      post(log_in_user(conn, user), ~p"/account/nerve/extension/connect", %{
        "return_to" => return_to,
        "state" => "state-123"
      })

    redirect = redirected_to(conn, 302)
    assert String.starts_with?(redirect, return_to <> "#")

    params = redirect |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query()
    assert params["state"] == "state-123"
    assert params["token_type"] == "pat"
    assert String.starts_with?(params["token"], "ekt_")
    assert %{"values" => %{"color_primary" => _primary}} = Jason.decode!(params["theme"])

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{params["token"]}")
      |> get("/api/ext/v1/nerve/entries")

    assert %{"data" => %{"entries" => []}} = json_response(conn, 200)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{params["token"]}")
      |> post("/api/ext/v1/kairo/sources", %{
        "source" => %{
          "source_type" => "url",
          "title" => "Captured page",
          "url" => "https://example.com/article"
        }
      })

    assert %{"data" => %{"source" => %{"title" => "Captured page"}}} =
             json_response(conn, 201)
  end

  test "authorizes extension connection when stale extension token fills the quota", %{
    conn: conn,
    user: user
  } do
    seed_token_limit_with_stale_extension(user)

    return_to = "https://abc123.chromiumapp.org/nerve"

    conn =
      post(log_in_user(conn, user), ~p"/account/nerve/extension/connect", %{
        "return_to" => return_to
      })

    redirect = redirected_to(conn, 302)
    params = redirect |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query()

    assert String.starts_with?(params["token"], "ekt_")
    assert Developer.count_api_tokens(user.id) == Developer.max_tokens_per_user()

    active_extension_tokens =
      user.id
      |> Developer.list_api_tokens()
      |> Enum.filter(&(&1.name == "Nerve browser extension"))

    assert Enum.map(active_extension_tokens, & &1.token_prefix) == [
             String.slice(params["token"], 0, 12)
           ]
  end

  test "authorizes extension pairing for normal browser tabs", %{conn: conn, user: user} do
    pairing_id = String.duplicate("a", 32)
    pairing_secret = String.duplicate("b", 64)

    pending_conn =
      get(build_conn(), "/api/ext/v1/nerve/extension/connect/#{pairing_id}", %{
        "secret" => pairing_secret
      })

    assert %{"status" => "pending"} = json_response(pending_conn, 202)

    conn =
      post(log_in_user(conn, user), ~p"/account/nerve/extension/connect", %{
        "pairing_id" => pairing_id,
        "pairing_secret" => pairing_secret,
        "state" => "state-123"
      })

    assert html_response(conn, 200) =~ "Extension Connected"

    connected_conn =
      get(build_conn(), "/api/ext/v1/nerve/extension/connect/#{pairing_id}", %{
        "secret" => pairing_secret
      })

    response = json_response(connected_conn, 200)
    assert response["status"] == "connected"
    assert String.starts_with?(response["token"], "ekt_")
    assert response["user"]["username"] == user.username

    consumed_conn =
      get(build_conn(), "/api/ext/v1/nerve/extension/connect/#{pairing_id}", %{
        "secret" => pairing_secret
      })

    assert %{"status" => "pending"} = json_response(consumed_conn, 202)
  end

  defp seed_token_limit_with_stale_extension(user) do
    for idx <- 1..(Developer.max_tokens_per_user() - 1) do
      assert {:ok, _token} =
               Developer.create_api_token(user.id, %{
                 name: "manual-token-#{idx}",
                 scopes: ["read:account"]
               })
    end

    assert {:ok, _token} =
             Developer.create_api_token(user.id, %{
               name: "Nerve browser extension",
               scopes: ["read:nerve", "write:nerve"]
             })
  end
end
