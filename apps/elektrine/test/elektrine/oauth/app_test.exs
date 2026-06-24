defmodule Elektrine.OAuth.AppTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.OAuth
  alias Elektrine.OAuth.App

  test "rejects native redirect URI schemes and non-localhost http" do
    for redirect_uri <- [
          "mastodon://oauth",
          "mammoth://oauth",
          "feditext://oauth",
          "fedicat://oauth",
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

  test "base changeset rejects unsafe redirect URI updates" do
    {:ok, app} =
      OAuth.create_app(%{
        client_name: "Console",
        redirect_uris: "https://client.example/callback",
        scopes: ["read"]
      })

    changeset = App.changeset(app, %{redirect_uris: "http://client.example/callback"})

    refute changeset.valid?
    assert "contains invalid URI" in errors_on(changeset).redirect_uris
  end

  test "rejects unknown and privileged self-service scopes" do
    for scopes <- [["read", "unknown:scope"], ["read", "admin:write"]] do
      assert {:error, changeset} =
               OAuth.create_app(%{
                 client_name: "Unsafe scopes",
                 redirect_uris: "https://client.example/callback",
                 scopes: scopes
               })

      assert %{scopes: [_ | _]} = errors_on(changeset)
    end
  end
end
