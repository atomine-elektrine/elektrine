defmodule Elektrine.DomainsTest do
  use ExUnit.Case, async: true

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

  test "uses the primary configured profile domain for built-in profile URLs" do
    Application.put_env(:elektrine, :email, domain: "selfhost.test")
    Application.put_env(:elektrine, :profile_base_domains, ["selfhost.test", "z.org"])

    assert Domains.default_profile_domain() == "selfhost.test"
    assert Domains.default_profile_url_for_handle("alice") == "https://alice.selfhost.test"
  end

  test "does not treat supported email domains as built-in profile domains by default" do
    Application.put_env(:elektrine, :email,
      domain: "elektrine.com",
      supported_domains: ["elektrine.com", "elektrine.net", "elektrine.org", "z.org"]
    )

    Application.delete_env(:elektrine, :profile_base_domains)

    assert Domains.configured_profile_base_domains() == ["elektrine.com"]
    assert Domains.default_profile_url_for_handle("alice") == "https://alice.elektrine.com"
    assert Domains.profile_urls_for_handle("alice") == ["https://alice.elektrine.com"]
  end

  test "canonicalizes profile URLs to the primary configured profile domain on built-in hosts" do
    Application.put_env(:elektrine, :email, domain: "selfhost.test")
    Application.put_env(:elektrine, :profile_base_domains, ["selfhost.test", "z.org"])

    assert Domains.profile_url_for_handle("alice", "alice.z.org") ==
             "https://alice.selfhost.test"
  end
end
