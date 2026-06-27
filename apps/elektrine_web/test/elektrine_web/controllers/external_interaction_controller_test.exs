defmodule ElektrineWeb.ExternalInteractionControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub

  setup do
    previous_email_config = Application.get_env(:elektrine, :email)
    previous_profile_base_domains = Application.get_env(:elektrine, :profile_base_domains)

    Application.put_env(:elektrine, :email,
      domain: "elektrine.com",
      supported_domains: ["elektrine.com", "elektrine.net", "elektrine.org"]
    )

    Application.put_env(:elektrine, :profile_base_domains, ["elektrine.com"])

    on_exit(fn ->
      if is_nil(previous_email_config) do
        Application.delete_env(:elektrine, :email)
      else
        Application.put_env(:elektrine, :email, previous_email_config)
      end

      if is_nil(previous_profile_base_domains) do
        Application.delete_env(:elektrine, :profile_base_domains)
      else
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_base_domains)
      end
    end)

    :ok
  end

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
