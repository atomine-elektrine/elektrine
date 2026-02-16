defmodule Elektrine.CustomDomains.SSLConfigTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.CustomDomains.SSLConfig
  alias Elektrine.CustomDomains.MainDomainCerts

  describe "sni_fun/1" do
    test "handles charlist hostname" do
      # SNI callbacks receive hostnames as charlists
      result = SSLConfig.sni_fun(~c"example.com")

      # Should return :undefined for unknown domains (no cert available)
      assert result == :undefined
    end

    test "handles binary hostname" do
      result = SSLConfig.sni_fun("example.com")

      assert result == :undefined
    end

    test "is case-insensitive" do
      result1 = SSLConfig.sni_fun("EXAMPLE.COM")
      result2 = SSLConfig.sni_fun("example.com")

      assert result1 == result2
    end

    test "recognizes main domains" do
      # Main domains should attempt to load from disk
      # If no real certs exist, bootstrap certs are generated and returned
      for domain <- MainDomainCerts.main_domains() do
        result = SSLConfig.sni_fun(domain)
        # Should return SSL options with cert and key (bootstrap or real)
        assert is_list(result) and Keyword.has_key?(result, :cert) and
                 Keyword.has_key?(result, :key)
      end
    end

    test "recognizes subdomains of main domains" do
      # Subdomains like user.z.org should use parent domain cert
      result = SSLConfig.sni_fun("someuser.z.org")

      # Should return SSL options (bootstrap cert is generated for parent domain)
      assert is_list(result) and Keyword.has_key?(result, :cert) and
               Keyword.has_key?(result, :key)
    end

    test "returns undefined for unknown domains" do
      result = SSLConfig.sni_fun("custom-domain.com")

      # Without cached cert, returns :undefined
      assert result == :undefined
    end
  end

  describe "enabled?/0" do
    test "returns boolean based on config" do
      result = SSLConfig.enabled?()

      assert is_boolean(result)
    end
  end

  describe "default_ssl_options/0" do
    test "returns nil when cert files don't exist" do
      # In test environment, cert files likely don't exist
      result = SSLConfig.default_ssl_options()

      assert result == nil
    end
  end

  describe "main_domain? detection" do
    test "elektrine.com is a main domain" do
      # Test via sni_fun behavior - main domains go through load_main_domain_cert
      # We can verify the function recognizes main domains
      assert "elektrine.com" in MainDomainCerts.main_domains()
    end

    test "z.org is a main domain" do
      assert "z.org" in MainDomainCerts.main_domains()
    end

    test "random.com is not a main domain" do
      refute "random.com" in MainDomainCerts.main_domains()
    end
  end

  describe "subdomain detection" do
    test "user.z.org is a subdomain of main domain" do
      # This is implicitly tested - subdomain_of_main? should return true
      # and the parent domain (z.org) should be used for cert lookup
      result = SSLConfig.sni_fun("user.z.org")

      # Returns SSL options with bootstrap cert (z.org parent domain cert)
      assert is_list(result) and Keyword.has_key?(result, :cert) and
               Keyword.has_key?(result, :key)
    end

    test "deeply nested subdomain is recognized" do
      result = SSLConfig.sni_fun("deep.nested.z.org")

      # Returns SSL options with bootstrap cert (z.org parent domain cert)
      assert is_list(result) and Keyword.has_key?(result, :cert) and
               Keyword.has_key?(result, :key)
    end

    test "user.random.com is not a subdomain of main domain" do
      result = SSLConfig.sni_fun("user.random.com")

      assert result == :undefined
    end

    test "main domains are correctly identified" do
      assert "elektrine.com" in MainDomainCerts.main_domains()
      assert "z.org" in MainDomainCerts.main_domains()
      refute "random.com" in MainDomainCerts.main_domains()
    end
  end
end
