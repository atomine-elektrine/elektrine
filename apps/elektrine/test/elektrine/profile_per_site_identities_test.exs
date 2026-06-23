defmodule Elektrine.ProfilePerSiteIdentitiesTest do
  use Elektrine.DataCase, async: true

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.Domains
  alias Elektrine.Profiles
  alias Elektrine.Repo

  describe "per-site portable identities" do
    test "creates an identity under the user's built-in profile domain" do
      user = user_fixture(%{username: "persitebuiltin", handle: "persitebuiltin"})
      base_domain = "persitebuiltin.#{Domains.default_profile_domain()}"

      assert {:ok, identity} =
               Profiles.create_per_site_identity(user, %{
                 "site_key" => "hn",
                 "base_domain" => base_domain,
                 "display_name" => "Hacker News"
               })

      assert identity.site_key == "hn"
      assert identity.base_domain == base_domain
      assert identity.domain == "hn.#{base_domain}"
      assert identity.subject == "domain:hn.#{base_domain}"
      assert identity.did == "did:web:hn.#{base_domain}"
      assert identity.email_alias == "hn@#{base_domain}"
      assert identity.display_name == "Hacker News"
      assert identity.enabled == true
    end

    test "rejects a base domain the user does not own" do
      user = user_fixture(%{username: "persiteinvalid", handle: "persiteinvalid"})

      assert {:error, :invalid_base_domain} =
               Profiles.create_per_site_identity(user, %{
                 "site_key" => "banking",
                 "base_domain" => "someone-else.example"
               })
    end

    test "creates an identity under a verified custom profile domain" do
      user = user_fixture(%{username: "persitecustom", handle: "persitecustom"})
      custom_domain = verified_profile_custom_domain_fixture(user, "persitecustom.example")

      assert {:ok, identity} =
               Profiles.create_per_site_identity(user, %{
                 "site_key" => "spotify",
                 "base_domain" => custom_domain.domain
               })

      assert identity.domain == "spotify.persitecustom.example"
      assert custom_domain.domain in Profiles.available_per_site_base_domains(user)
    end

    test "keeps one identity per site key and base domain for each user" do
      user = user_fixture(%{username: "persiteunique", handle: "persiteunique"})
      base_domain = "persiteunique.#{Domains.default_profile_domain()}"

      assert {:ok, _identity} =
               Profiles.create_per_site_identity(user, %{
                 "site_key" => "hn",
                 "base_domain" => base_domain
               })

      assert {:error, changeset} =
               Profiles.create_per_site_identity(user, %{
                 "site_key" => "hn",
                 "base_domain" => base_domain
               })

      assert "already exists for that domain" in errors_on(changeset).site_key
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
