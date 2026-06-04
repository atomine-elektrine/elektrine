defmodule Elektrine.DomainsTest do
  use ExUnit.Case, async: false

  alias Elektrine.Accounts.User
  alias Elektrine.Domains

  setup do
    previous_port = System.get_env("PORT")
    previous_environment = Application.get_env(:elektrine, :environment)
    previous_profile_base_domains = Application.get_env(:elektrine, :profile_base_domains)

    previous_email_config = Application.get_env(:elektrine, :email)

    on_exit(fn ->
      if is_nil(previous_port),
        do: System.delete_env("PORT"),
        else: System.put_env("PORT", previous_port)

      if is_nil(previous_environment) do
        Application.delete_env(:elektrine, :environment)
      else
        Application.put_env(:elektrine, :environment, previous_environment)
      end

      if is_nil(previous_profile_base_domains) do
        Application.delete_env(:elektrine, :profile_base_domains)
      else
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_base_domains)
      end

      if is_nil(previous_email_config) do
        Application.delete_env(:elektrine, :email)
      else
        Application.put_env(:elektrine, :email, previous_email_config)
      end
    end)

    :ok
  end

  test "uses http with configured port for local development domains" do
    Application.put_env(:elektrine, :environment, :dev)
    System.put_env("PORT", "4100")

    assert Domains.inferred_base_url_for_domain("localhost") == "http://localhost:4100"
  end

  test "uses https without port for public tunnel domains in development" do
    Application.put_env(:elektrine, :environment, :dev)
    System.put_env("PORT", "4100")

    assert Domains.inferred_base_url_for_domain("z.example.com") == "https://z.example.com"
  end

  test "uses https without port in production" do
    Application.put_env(:elektrine, :environment, :prod)
    System.put_env("PORT", "4100")

    assert Domains.inferred_base_url_for_domain("localhost") == "https://localhost"
  end

  test "default hosted Elektrine config offers alternate official domains" do
    assert "elektrine.net" in Domains.receiving_email_domains()
    assert "elektrine.org" in Domains.receiving_email_domains()
    assert "elektrine.net" in Domains.available_email_domains_for_user(123)
    assert "elektrine.org" in Domains.available_email_domains_for_user(123)
  end

  test "uses the primary configured profile domain for enabled built-in profile subdomains" do
    Application.put_env(:elektrine, :email, domain: "selfhost.test")
    Application.put_env(:elektrine, :profile_base_domains, ["selfhost.test", "z.org"])
    user = %User{handle: "alice", username: "alice", built_in_subdomain_mode: "platform"}

    assert Domains.default_profile_domain() == "selfhost.test"
    assert Domains.default_profile_url_for_user(user) == "https://alice.selfhost.test"
  end

  test "uses path-based profile URLs until the user enables subdomain hosting" do
    Application.put_env(:elektrine, :email, domain: "elektrine.com")
    Application.put_env(:elektrine, :profile_base_domains, ["elektrine.com"])
    user = %User{handle: "alice", username: "alice", built_in_subdomain_mode: "path"}

    assert Domains.default_profile_url_for_handle("alice") == "https://elektrine.com/alice"
    assert Domains.profile_url_for_handle("alice") == "https://elektrine.com/alice"
    assert Domains.profile_url_for_user(user) == "https://elektrine.com/alice"
    assert Domains.default_profile_url_for_user(user) == "https://elektrine.com/alice"
  end

  test "does not treat supported email domains as built-in profile domains by default" do
    Application.put_env(:elektrine, :email,
      domain: "elektrine.com",
      supported_domains: ["elektrine.com", "elektrine.net", "elektrine.org", "z.org"]
    )

    Application.delete_env(:elektrine, :profile_base_domains)

    assert Domains.configured_profile_base_domains() == ["elektrine.com"]
    assert Domains.default_profile_url_for_handle("alice") == "https://elektrine.com/alice"
    assert Domains.profile_urls_for_handle("alice") == ["https://alice.elektrine.com"]
  end

  test "treats secondary supported domains as receive-only" do
    Application.put_env(:elektrine, :email,
      domain: "elektrine.com",
      supported_domains: ["elektrine.com", "z.org"]
    )

    Application.put_env(:elektrine, :profile_base_domains, ["elektrine.com", "z.org"])

    assert Domains.supported_email_domains() == ["elektrine.com"]
    assert "z.org" in Domains.receiving_email_domains()
    refute "z.org" in Domains.available_email_domains_for_user(123)
    refute "z.org" in Domains.configured_profile_base_domains()
    refute "z.org" in Domains.activitypub_domains()
  end

  test "canonicalizes profile URLs to the primary configured profile domain on built-in hosts" do
    Application.put_env(:elektrine, :email, domain: "selfhost.test")
    Application.put_env(:elektrine, :profile_base_domains, ["selfhost.test", "z.org"])

    assert Domains.profile_url_for_handle("alice", "alice.z.org") ==
             "https://selfhost.test/alice"
  end
end
