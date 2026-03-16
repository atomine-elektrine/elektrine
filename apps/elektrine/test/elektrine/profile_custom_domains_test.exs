defmodule Elektrine.ProfileCustomDomainsTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Profiles

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

    on_exit(fn ->
      if previous_resolver do
        Application.put_env(:elektrine, :profile_custom_domain_txt_resolver, previous_resolver)
      else
        Application.delete_env(:elektrine, :profile_custom_domain_txt_resolver)
      end
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
end
