defmodule ElektrineWeb.CustomDomainIdentityControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts.User
  alias Elektrine.Profiles
  alias Elektrine.Repo

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

  describe "GET /.well-known/domain-account" do
    test "publishes the portable identity document on a verified custom profile domain", %{
      conn: conn
    } do
      user =
        user_fixture(%{
          username: "domainaccount",
          handle: "domainaccount",
          display_name: "Domain Account"
        })

      custom_domain = verified_profile_custom_domain_fixture(user, "portable.example")

      assert {:ok, _identity} =
               Profiles.create_per_site_identity(user, %{
                 "site_key" => "hn",
                 "base_domain" => custom_domain.domain
               })

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/domain-account")

      response = json_response(conn, 200)

      assert response["version"] == 1
      assert response["id"] == "https://portable.example/"
      assert response["subject"] == "domain:portable.example"
      assert response["domain"] == "portable.example"
      assert response["portable"] == true
      assert response["hosted_by"] == Elektrine.Domains.public_base_url()

      assert response["auth"]["subject"] == "domain:portable.example"
      assert response["auth"]["oidc_issuer"] == Elektrine.Domains.public_base_url()
      assert response["auth"]["oidc_discovery"] =~ "/.well-known/openid-configuration"
      assert response["auth"]["authorization_endpoint"] =~ "/oauth/authorize"
      assert response["auth"]["authorization_endpoint"] =~ "identity_domain=portable.example"
      assert response["auth"]["identity_domain"] == "portable.example"

      assert response["atomine"]["issuer"] == Elektrine.Domains.public_base_url()
      assert response["atomine"]["proof_bundle"] == "https://portable.example/.well-known/atomine"
      assert response["atomine"]["subject"] == "domain:portable.example"
      assert response["atomine"]["jwks_uri"] =~ "/oauth/jwks"

      assert response["federation"]["activitypub_actor"] ==
               "https://portable.example/users/domainaccount"

      assert response["federation"]["activitypub_webfinger"] ==
               "acct:domainaccount@portable.example"

      assert response["federation"]["arblarg"] ==
               "https://portable.example/.well-known/_arblarg"

      assert response["email"]["primary_address"] == "domainaccount@portable.example"

      assert response["per_site_identities"]["subject_template"] ==
               "domain:{site}.portable.example"

      assert [
               %{
                 "site_key" => "hn",
                 "domain" => "hn.portable.example",
                 "subject" => "domain:hn.portable.example",
                 "did" => "did:web:hn.portable.example",
                 "email_alias" => "hn@portable.example",
                 "enabled" => true
               }
             ] = response["per_site_identities"]["identities"]

      assert response["recovery"]["export_available"] == true
      assert response["recovery"]["portable_root"] == "dns"
    end

    test "publishes the Atomine proof bundle on a verified custom profile domain", %{
      conn: conn
    } do
      user =
        user_fixture(%{
          username: "atomineproofbundle",
          handle: "atomineproofbundle",
          display_name: "Atomine Proof Bundle"
        })

      custom_domain = verified_profile_custom_domain_fixture(user, "proofbundle.example")

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/atomine")

      response = json_response(conn, 200)

      assert response["type"] == "atomine.proof_bundle"
      assert response["subject"] == "domain:proofbundle.example"
      assert response["did"] == "did:web:proofbundle.example"
      assert response["issuer"] == Elektrine.Domains.public_base_url()
      assert response["profile"]["atomine"] == "https://proofbundle.example/.well-known/atomine"

      assert Enum.any?(
               response["claims"],
               &(&1["type"] == "domain.verified" and &1["value"] == true)
             )

      assert Enum.any?(
               response["claims"],
               &(&1["type"] == "activitypub.actor" and
                   &1["value"] == "https://proofbundle.example/users/atomineproofbundle")
             )

      assert response["signature"]["format"] == "jws"
      assert response["signature"]["alg"] == "RS256"
      assert response["signature"]["jwks_uri"] =~ "/oauth/jwks"
      assert [_, _, _] = String.split(response["signature"]["value"], ".")
    end

    test "also publishes the Elektrine-namespaced discovery alias", %{conn: conn} do
      user = user_fixture(%{username: "elektrinedomainaccount"})
      custom_domain = verified_profile_custom_domain_fixture(user, "elektrineportable.example")

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/elektrine")

      assert %{"subject" => "domain:elektrineportable.example"} = json_response(conn, 200)
    end

    test "publishes the portable identity document on built-in handle subdomains", %{conn: conn} do
      user_fixture(%{username: "builtinaccount", handle: "builtinaccount"})
      domain = "builtinaccount.#{Elektrine.Domains.default_profile_domain()}"

      conn =
        conn
        |> Map.put(:host, domain)
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/domain-account")

      response = json_response(conn, 200)

      assert response["subject"] == "domain:#{domain}"

      assert response["federation"]["activitypub_actor"] ==
               "https://#{domain}/users/builtinaccount"

      assert response["auth"]["oidc_issuer"] == Elektrine.Domains.public_base_url()
    end

    test "publishes the Atomine proof bundle on built-in handle subdomains", %{conn: conn} do
      user_fixture(%{username: "builtinproofs", handle: "builtinproofs"})
      domain = "builtinproofs.#{Elektrine.Domains.default_profile_domain()}"

      conn =
        conn
        |> Map.put(:host, domain)
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/atomine")

      response = json_response(conn, 200)

      assert response["subject"] == "domain:#{domain}"
      assert response["profile"]["atomine"] == "https://#{domain}/.well-known/atomine"
    end

    test "returns not found for unverified hosts", %{conn: conn} do
      conn =
        conn
        |> Map.put(:host, "unknown.example")
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/domain-account")

      assert json_response(conn, 404) == %{"error" => "domain_account_not_found"}
    end
  end

  describe "GET /.well-known/did.json" do
    test "publishes a did:web document for a verified custom profile domain", %{conn: conn} do
      user = user_fixture(%{username: "didaccount", handle: "didaccount"})
      custom_domain = verified_profile_custom_domain_fixture(user, "didportable.example")

      conn =
        conn
        |> Map.put(:host, custom_domain.domain)
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/did.json")

      response = json_response(conn, 200)

      assert response["@context"] == ["https://www.w3.org/ns/did/v1"]
      assert response["id"] == "did:web:didportable.example"

      assert "https://didportable.example/" in response["alsoKnownAs"]
      assert "acct:didaccount@didportable.example" in response["alsoKnownAs"]
      assert "https://didportable.example/users/didaccount" in response["alsoKnownAs"]

      assert %{
               "id" => "did:web:didportable.example#domain-account",
               "type" => "DomainAccount",
               "serviceEndpoint" => "https://didportable.example/.well-known/domain-account"
             } in response["service"]

      assert %{
               "id" => "did:web:didportable.example#openid-connect",
               "type" => "OpenIDConnectIssuer",
               "serviceEndpoint" => Elektrine.Domains.public_base_url()
             } in response["service"]

      assert %{
               "id" => "did:web:didportable.example#activitypub",
               "type" => "ActivityPubActor",
               "serviceEndpoint" => "https://didportable.example/users/didaccount"
             } in response["service"]
    end

    test "returns not found for DID requests on unverified hosts", %{conn: conn} do
      conn =
        conn
        |> Map.put(:host, "unknown.example")
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/did.json")

      assert json_response(conn, 404) == %{"error" => "did_not_found"}
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
