defmodule ElektrineWeb.CustomDomainIdentityControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Accounts.User

  describe "GET /.well-known/atproto-did" do
    test "returns the Bluesky DID for a verified custom profile domain", %{conn: conn} do
      user = user_fixture(%{username: "bskycustomdomainalias"})
      custom_domain = verified_profile_custom_domain_fixture(user, "bskycustomalias.test")

      from(u in User, where: u.id == ^user.id)
      |> Repo.update_all(set: [bluesky_did: "did:plc:customdomainalias"])

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> get("/.well-known/atproto-did")

      assert response(conn, 200) == "did:plc:customdomainalias"
    end

    test "returns not found when the custom domain owner has no Bluesky DID", %{conn: conn} do
      user = user_fixture(%{username: "noblueskycustomdomain"})
      custom_domain = verified_profile_custom_domain_fixture(user, "noblueskyalias.test")

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> get("/.well-known/atproto-did")

      assert response(conn, 404) == "Not found"
    end
  end

  describe "GET /.well-known/_arblarg" do
    test "publishes Arblarg discovery on verified custom profile domains", %{conn: conn} do
      user = user_fixture(%{username: "arblargcustomdomain"})
      custom_domain = verified_profile_custom_domain_fixture(user, "arblargalias.test")

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/_arblarg")

      response = json_response(conn, 200)

      assert response["domain"] == custom_domain.domain

      assert response["endpoints"]["well_known"] ==
               "https://#{custom_domain.domain}/.well-known/_arblarg"

      assert response["endpoints"]["events"] == "https://#{custom_domain.domain}/_arblarg/events"

      assert response["endpoints"]["session_websocket"] ==
               "wss://#{custom_domain.domain}/_arblarg/session"
    end
  end

  defp verified_profile_custom_domain_fixture(user, domain) do
    {:ok, custom_domain} = Profiles.create_custom_domain(user, %{"domain" => domain})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      from(d in Elektrine.Profiles.CustomDomain, where: d.id == ^custom_domain.id)
      |> Repo.update_all(set: [status: "verified", verified_at: now, last_checked_at: now])

    Profiles.get_verified_custom_domain(domain)
  end
end
