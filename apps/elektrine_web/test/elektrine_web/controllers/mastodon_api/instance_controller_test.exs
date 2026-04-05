defmodule ElektrineSocialWeb.MastodonAPI.InstanceControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.ActivityPub.Instance
  alias Elektrine.Repo

  describe "GET /api/v1/instance/peers" do
    test "returns tracked ActivityPub instance domains", %{conn: conn} do
      Repo.insert!(%Instance{domain: "mastodon.social"})
      Repo.insert!(%Instance{domain: "example.com"})

      conn = get(conn, ~p"/api/v1/instance/peers")

      assert Enum.sort(json_response(conn, 200)) == ["example.com", "mastodon.social"]
    end
  end
end
