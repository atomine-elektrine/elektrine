defmodule Elektrine.ProfileCustomDomainsTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.{Domains, Profiles}
  alias Elektrine.Profiles.CustomDomain

  defmodule TestTxtResolver do
    @behaviour Elektrine.Profiles.CustomDomains

    @impl true
    def lookup_txt(host) do
      Process.get({__MODULE__, host}, {:ok, []})
    end
  end

  setup do
    previous_resolver = Application.get_env(:elektrine, :profile_custom_domain_txt_resolver)
    Application.put_env(:elektrine, :profile_custom_domain_txt_resolver, TestTxtResolver)

    previous_edge_env =
      for key <- [
            "PROFILE_CUSTOM_DOMAIN_EDGE_TARGET",
            "PROFILE_CUSTOM_DOMAIN_EDGE_IPV4",
            "PROFILE_CUSTOM_DOMAIN_EDGE_IPV6"
          ],
          into: %{} do
        {key, System.get_env(key)}
      end

    Enum.each(Map.keys(previous_edge_env), &System.delete_env/1)

    on_exit(fn ->
      if previous_resolver do
        Application.put_env(:elektrine, :profile_custom_domain_txt_resolver, previous_resolver)
      else
        Application.delete_env(:elektrine, :profile_custom_domain_txt_resolver)
      end

      Enum.each(previous_edge_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "verify_custom_domain marks a profile domain verified when the TXT record matches" do
    user = user_fixture(%{username: "profiledomainowner"})

    {:ok, custom_domain} =
      Profiles.create_custom_domain(user, %{"domain" => "profiledomainowner.test"})

    Process.put(
      {TestTxtResolver, Profiles.verification_host(custom_domain)},
      {:ok, [Profiles.verification_value(custom_domain)]}
    )

    assert {:ok, verified_domain} = Profiles.verify_custom_domain(custom_domain)
    assert verified_domain.status == "verified"
    assert Profiles.get_verified_custom_domain("profiledomainowner.test").id == verified_domain.id
  end

  test "re-verifying keeps a profile domain verified within the grace window" do
    user = user_fixture(%{username: "profilegrace"})

    {:ok, custom_domain} =
      Profiles.create_custom_domain(user, %{"domain" => "profilegrace.test"})

    Process.put(
      {TestTxtResolver, Profiles.verification_host(custom_domain)},
      {:ok, [Profiles.verification_value(custom_domain)]}
    )

    assert {:ok, verified} = Profiles.verify_custom_domain(custom_domain)
    assert verified.status == "verified"

    # Record disappears from DNS.
    Process.put({TestTxtResolver, Profiles.verification_host(custom_domain)}, {:ok, []})

    assert {:ok, still_verified} = Profiles.verify_custom_domain(verified)
    assert still_verified.status == "verified"
    assert still_verified.failing_since
  end

  test "re-verifying demotes a profile domain to pending after the grace window" do
    user = user_fixture(%{username: "profilegracepass"})

    {:ok, custom_domain} =
      Profiles.create_custom_domain(user, %{"domain" => "profilegracepass.test"})

    Process.put(
      {TestTxtResolver, Profiles.verification_host(custom_domain)},
      {:ok, [Profiles.verification_value(custom_domain)]}
    )

    assert {:ok, verified} = Profiles.verify_custom_domain(custom_domain)

    failing_since = DateTime.utc_now() |> DateTime.add(-5 * 24 * 60 * 60, :second)

    stale =
      verified
      |> Ecto.Changeset.change(failing_since: DateTime.truncate(failing_since, :second))
      |> Elektrine.Repo.update!()

    Process.put({TestTxtResolver, Profiles.verification_host(custom_domain)}, {:ok, []})

    assert {:ok, demoted} = Profiles.verify_custom_domain(stale)
    assert demoted.status == "pending"
    assert is_nil(demoted.failing_since)
    assert is_nil(Profiles.get_verified_custom_domain("profilegracepass.test"))
  end

  test "get_verified_custom_domain_for_host resolves bare and www hosts" do
    user = user_fixture(%{username: "profilehostowner"})

    {:ok, custom_domain} =
      Profiles.create_custom_domain(user, %{"domain" => "profilehostowner.test"})

    Process.put(
      {TestTxtResolver, Profiles.verification_host(custom_domain)},
      {:ok, [Profiles.verification_value(custom_domain)]}
    )

    assert {:ok, verified_domain} = Profiles.verify_custom_domain(custom_domain)

    assert Profiles.get_verified_custom_domain_for_host("profilehostowner.test").id ==
             verified_domain.id

    assert Profiles.get_verified_custom_domain_for_host("www.profilehostowner.test").id ==
             verified_domain.id
  end

  test "rejects domains that conflict with configured profile hosts" do
    user = user_fixture(%{username: "conflictingprofiledomain"})

    assert {:error, changeset} =
             Profiles.create_custom_domain(
               user,
               %{"domain" => "foo.#{Domains.primary_profile_domain()}"}
             )

    assert "conflicts with an existing profile host" in errors_on(changeset).domain
  end

  test "rejects the configured profile routing edge target" do
    System.put_env("PROFILE_CUSTOM_DOMAIN_EDGE_TARGET", "profiles.edge.example")
    user = user_fixture(%{username: "reservedprofileedge"})

    assert {:error, changeset} =
             Profiles.create_custom_domain(user, %{"domain" => "profiles.edge.example"})

    assert "is reserved for profile routing" in errors_on(changeset).domain
  end

  test "rejects the www alias of the profile routing edge target" do
    System.put_env("PROFILE_CUSTOM_DOMAIN_EDGE_TARGET", "profiles.edge.example")
    user = user_fixture(%{username: "reservedprofileedgewww"})

    assert {:error, changeset} =
             Profiles.create_custom_domain(user, %{"domain" => "www.profiles.edge.example"})

    assert "is reserved for profile routing" in errors_on(changeset).domain
  end

  test "dns_records_for_custom_domain uses a stable hostname target instead of edge IPs" do
    System.put_env("PROFILE_CUSTOM_DOMAIN_EDGE_TARGET", "profiles.edge.example")
    System.put_env("PROFILE_CUSTOM_DOMAIN_EDGE_IPV4", "203.0.113.10")
    System.put_env("PROFILE_CUSTOM_DOMAIN_EDGE_IPV6", "2001:db8::10")

    custom_domain = %CustomDomain{
      domain: "futureproof.example",
      verification_token: "futureproof-token"
    }

    records = Profiles.dns_records_for_custom_domain(custom_domain)

    assert Enum.any?(records, fn record ->
             record.type == "ALIAS" and
               record.host == "futureproof.example" and
               record.value == "profiles.edge.example"
           end)

    refute Enum.any?(records, &(&1.type in ["A", "AAAA"]))
  end

  test "dns_records_for_custom_domain falls back to the configured routing target" do
    custom_domain = %CustomDomain{
      domain: "fallback.example",
      verification_token: "fallback-token"
    }

    records = Profiles.dns_records_for_custom_domain(custom_domain)

    assert Enum.any?(records, fn record ->
             record.type == "ALIAS" and
               record.host == "fallback.example" and
               record.value == Domains.profile_custom_domain_routing_target()
           end)
  end

  test "list_custom_domains_admin returns every user's profile domains with the owner" do
    owner_a = user_fixture(%{username: "adminlistowner1"})
    owner_b = user_fixture(%{username: "adminlistowner2"})

    {:ok, _} = Profiles.create_custom_domain(owner_a, %{"domain" => "adminlist-one.test"})
    {:ok, _} = Profiles.create_custom_domain(owner_b, %{"domain" => "adminlist-two.test"})

    {domains, total} = Profiles.CustomDomains.list_custom_domains_admin()

    assert total == 2
    listed = Enum.map(domains, & &1.domain)
    assert "adminlist-one.test" in listed
    assert "adminlist-two.test" in listed
    # Owner is preloaded so the admin view can link to the user.
    assert Enum.all?(domains, &is_struct(&1.user, Elektrine.Accounts.User))
  end

  test "list_custom_domains_admin filters by status and searches by domain/owner" do
    owner = user_fixture(%{username: "adminsearchowner"})
    {:ok, _} = Profiles.create_custom_domain(owner, %{"domain" => "adminsearch.test"})

    assert {[], 0} = Profiles.CustomDomains.list_custom_domains_admin("", "verified")
    assert {[domain], 1} = Profiles.CustomDomains.list_custom_domains_admin("adminsearch", "all")
    assert domain.domain == "adminsearch.test"
    assert {[_], 1} = Profiles.CustomDomains.list_custom_domains_admin("adminsearchowner", "all")
    assert {[], 0} = Profiles.CustomDomains.list_custom_domains_admin("no-such-domain", "all")
  end

  test "custom_domain_admin_stats counts totals and pending domains" do
    owner = user_fixture(%{username: "adminstatsowner"})
    {:ok, _} = Profiles.create_custom_domain(owner, %{"domain" => "adminstats.test"})

    stats = Profiles.CustomDomains.custom_domain_admin_stats()

    assert stats.total >= 1
    assert stats.pending >= 1
    assert Map.has_key?(stats, :verified)
    assert Map.has_key?(stats, :attention)
  end
end
