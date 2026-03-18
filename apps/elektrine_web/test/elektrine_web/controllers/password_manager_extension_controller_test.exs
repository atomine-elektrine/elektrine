defmodule ElektrineWeb.PasswordManagerExtensionControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "vaultdownload#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    %{user: user}
  end

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "downloads the chromium extension archive", %{conn: conn, user: user} do
    conn = get(log_in_user(conn, user), ~p"/account/password-manager/extension/chromium/download")

    assert get_resp_header(conn, "content-type") == ["application/zip; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"elektrine-vault-extension-chromium.zip\""
           ]

    assert {:ok, files} = :zip.unzip(conn.resp_body, [:memory])

    assert {~c"manifest.json", manifest} =
             Enum.find(files, fn {name, _contents} -> name == ~c"manifest.json" end)

    assert manifest =~ "\"name\": \"Elektrine Vault\""
  end

  test "downloads the firefox extension archive", %{conn: conn, user: user} do
    conn = get(log_in_user(conn, user), ~p"/account/password-manager/extension/firefox/download")

    assert get_resp_header(conn, "content-type") == ["application/x-xpinstall; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"elektrine-vault-extension-firefox.xpi\""
           ]
  end
end
