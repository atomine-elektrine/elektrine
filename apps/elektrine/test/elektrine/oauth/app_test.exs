defmodule Elektrine.OAuth.AppTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.OAuth

  test "allows native app redirect URI schemes for Mastodon clients" do
    for redirect_uri <- [
          "mastodon://oauth",
          "mammoth://oauth",
          "feditext://oauth",
          "fedicat://oauth"
        ] do
      assert {:ok, app} =
               OAuth.create_app(%{
                 client_name: "Native #{redirect_uri}",
                 redirect_uris: redirect_uri,
                 scopes: ["read"]
               })

      assert app.redirect_uris == redirect_uri
    end
  end

  test "keeps rejecting unsafe redirect URI schemes and non-localhost http" do
    for redirect_uri <- [
          "http://client.example/callback",
          "javascript:alert(1)",
          "data:text/html,hello",
          "file:///tmp/callback",
          "mailto:user@example.com"
        ] do
      assert {:error, changeset} =
               OAuth.create_app(%{
                 client_name: "Unsafe #{redirect_uri}",
                 redirect_uris: redirect_uri,
                 scopes: ["read"]
               })

      assert "contains invalid URI" in errors_on(changeset).redirect_uris
    end
  end
end
