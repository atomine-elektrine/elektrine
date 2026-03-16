defmodule ElektrineWeb.ExternalInteractionControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub

  defp request(conn, path, params \\ %{}), do: get(conn, path, params)

  for path <- ["/authorize_interaction", "/activitypub/externalInteraction"] do
    describe "GET #{path}" do
      test "redirects community actor URIs to remote community profiles", %{conn: conn} do
        conn = request(conn, unquote(path), %{uri: "https://lemmy.world/c/technology"})

        assert redirected_to(conn, 302) == "/remote/!technology@lemmy.world"
      end

      test "redirects user actor URIs to remote profiles", %{conn: conn} do
        conn = request(conn, unquote(path), %{uri: "https://mastodon.social/@alice"})

        assert redirected_to(conn, 302) == "/remote/alice@mastodon.social"
      end

      test "redirects local actor URIs to local profiles", %{conn: conn} do
        user = AccountsFixtures.user_fixture(%{username: "maxfield"})
        uri = "https://#{ActivityPub.instance_domain()}/users/#{user.username}"

        conn = request(conn, unquote(path), %{uri: uri})

        assert redirected_to(conn, 302) == "/#{user.handle}"
      end

      test "redirects post URIs to remote post view", %{conn: conn} do
        uri = "https://mastodon.social/@alice/114070609836958271"
        conn = request(conn, unquote(path), %{uri: uri})

        assert redirected_to(conn, 302) == "/remote/post/#{URI.encode_www_form(uri)}"
      end

      test "supports acct URIs for communities", %{conn: conn} do
        conn = request(conn, unquote(path), %{uri: "acct:!technology@lemmy.world"})

        assert redirected_to(conn, 302) == "/remote/!technology@lemmy.world"
      end

      test "redirects home when uri is missing", %{conn: conn} do
        conn = request(conn, unquote(path))

        assert redirected_to(conn, 302) == "/"
      end
    end
  end
end
