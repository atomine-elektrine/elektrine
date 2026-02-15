defmodule Elektrine.CustomDomains.MainDomainCertsTest do
  use ExUnit.Case, async: true

  alias Elektrine.CustomDomains.MainDomainCerts

  describe "main_domains/0" do
    test "returns list of main domains" do
      domains = MainDomainCerts.main_domains()

      assert is_list(domains)
      assert "elektrine.com" in domains
      assert "z.org" in domains
    end

    test "domains are lowercase strings" do
      domains = MainDomainCerts.main_domains()

      Enum.each(domains, fn domain ->
        assert is_binary(domain)
        assert domain == String.downcase(domain)
      end)
    end
  end

  describe "certs_base_path/0" do
    test "returns the certificate storage path" do
      path = MainDomainCerts.certs_base_path()

      assert is_binary(path)
      assert String.contains?(path, "certs")
    end
  end

  describe "cert_path/1" do
    test "returns path for domain certificate" do
      path = MainDomainCerts.cert_path("elektrine.com")

      assert String.ends_with?(path, "fullchain.pem")
      assert String.contains?(path, "elektrine.com")
    end

    test "path includes domain directory" do
      path = MainDomainCerts.cert_path("z.org")

      assert String.contains?(path, "z.org")
    end
  end

  describe "key_path/1" do
    test "returns path for domain private key" do
      path = MainDomainCerts.key_path("elektrine.com")

      assert String.ends_with?(path, "privkey.pem")
      assert String.contains?(path, "elektrine.com")
    end
  end

  describe "check_certificate/1" do
    test "returns :missing when cert file doesn't exist" do
      result = MainDomainCerts.check_certificate("elektrine.com")

      # In test environment, certs don't exist
      assert result == :missing
    end

    test "returns :missing for non-existent domain" do
      result = MainDomainCerts.check_certificate("nonexistent.com")

      assert result == :missing
    end
  end

  describe "get_certificate/1" do
    test "returns :error when cert doesn't exist" do
      result = MainDomainCerts.get_certificate("elektrine.com")

      # In test environment without actual certs
      assert result == :error
    end
  end

  describe "provision_certificate/1" do
    # Note: We can't test actual ACME provisioning without mocking
    # These tests verify the function interface

    test "function exists and accepts domain" do
      # This would need ACME mocking to test properly
      # For now, we just verify the function is callable
      assert Code.ensure_loaded?(MainDomainCerts)
      assert function_exported?(MainDomainCerts, :provision_certificate, 1)
    end
  end

  describe "ensure_certificates/0" do
    test "function exists" do
      # This would provision all main domain certs
      # We can't run it in tests without mocking ACME
      assert Code.ensure_loaded?(MainDomainCerts)
      assert function_exported?(MainDomainCerts, :ensure_certificates, 0)
    end
  end
end
