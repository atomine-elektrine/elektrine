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
             Profiles.create_custom_domain(user, %{"domain" => "foo.elektrine.com"})

    assert "conflicts with an existing profile host" in errors_on(changeset).domain
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
             record.type == "ALIAS/CNAME" and
               record.host == "futureproof.example" and
               record.value == "profiles.edge.example"
           end)

    refute Enum.any?(records, &(&1.type in ["A", "AAAA"]))
  end

  test "dns_records_for_custom_domain falls back to the primary profile hostname" do
    custom_domain = %CustomDomain{
      domain: "fallback.example",
      verification_token: "fallback-token"
    }

    records = Profiles.dns_records_for_custom_domain(custom_domain)

    assert Enum.any?(records, fn record ->
             record.type == "ALIAS/CNAME" and
               record.host == "fallback.example" and
               record.value == Domains.primary_profile_domain()
           end)
  end
end
