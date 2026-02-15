defmodule Elektrine.CustomDomains.CustomDomainTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.CustomDomains.CustomDomain

  describe "create_changeset/2" do
    test "valid domain creates changeset with verification token" do
      # Use a mock user_id since changeset validation doesn't check FK
      # Note: example.com is reserved, use a different test domain
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          domain: "my-custom-site.com",
          user_id: 1
        })

      assert changeset.valid?
      assert get_change(changeset, :domain) == "my-custom-site.com"
      assert get_change(changeset, :verification_token) != nil
    end

    test "normalizes domain to lowercase" do
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          domain: "MY-CUSTOM-SITE.COM",
          user_id: 1
        })

      assert changeset.valid?
      assert get_change(changeset, :domain) == "my-custom-site.com"
    end

    test "rejects domain without TLD" do
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          domain: "localhost",
          user_id: 1
        })

      refute changeset.valid?
      assert "must be a valid domain name" in errors_on(changeset).domain
    end

    test "rejects domain with invalid characters" do
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          domain: "example_domain.com",
          user_id: 1
        })

      refute changeset.valid?
      assert "must be a valid domain name" in errors_on(changeset).domain
    end

    test "rejects reserved elektrine.com domain" do
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          domain: "elektrine.com",
          user_id: 1
        })

      refute changeset.valid?
      assert "is a reserved domain and cannot be used" in errors_on(changeset).domain
    end

    test "rejects reserved z.org subdomain" do
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          domain: "test.z.org",
          user_id: 1
        })

      refute changeset.valid?
      assert "is a reserved domain and cannot be used" in errors_on(changeset).domain
    end

    test "rejects fly.dev domains" do
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          domain: "myapp.fly.dev",
          user_id: 1
        })

      refute changeset.valid?
      assert "is a reserved domain and cannot be used" in errors_on(changeset).domain
    end

    test "rejects domains that are too short" do
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          domain: "a.b",
          user_id: 1
        })

      refute changeset.valid?
    end

    test "requires domain field" do
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          user_id: 1
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).domain
    end

    test "requires user_id field" do
      changeset =
        CustomDomain.create_changeset(%CustomDomain{}, %{
          domain: "example.com"
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end
  end

  describe "verification_changeset/2" do
    test "updates status to verified" do
      domain = %CustomDomain{status: "pending_verification"}

      changeset =
        CustomDomain.verification_changeset(domain, %{
          status: "verified",
          verified_at: DateTime.utc_now()
        })

      assert changeset.valid?
      assert get_change(changeset, :status) == "verified"
    end

    test "rejects invalid status" do
      domain = %CustomDomain{}

      changeset =
        CustomDomain.verification_changeset(domain, %{
          status: "invalid_status"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "allows updating error information" do
      domain = %CustomDomain{error_count: 0}

      changeset =
        CustomDomain.verification_changeset(domain, %{
          last_error: "DNS TXT record not found",
          error_count: 1
        })

      assert changeset.valid?
      assert get_change(changeset, :last_error) == "DNS TXT record not found"
      assert get_change(changeset, :error_count) == 1
    end
  end

  describe "acme_challenge_changeset/2" do
    test "stores ACME challenge data" do
      domain = %CustomDomain{}

      changeset =
        CustomDomain.acme_challenge_changeset(domain, %{
          acme_challenge_token: "test-token",
          acme_challenge_response: "test-response",
          status: "provisioning_ssl",
          ssl_status: "provisioning"
        })

      assert changeset.valid?
      assert get_change(changeset, :acme_challenge_token) == "test-token"
      assert get_change(changeset, :acme_challenge_response) == "test-response"
    end

    test "validates ssl_status" do
      domain = %CustomDomain{}

      changeset =
        CustomDomain.acme_challenge_changeset(domain, %{
          ssl_status: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).ssl_status
    end
  end

  describe "certificate_changeset/2" do
    test "stores certificate data" do
      domain = %CustomDomain{}
      expires_at = DateTime.utc_now() |> DateTime.add(90 * 24 * 60 * 60)

      changeset =
        CustomDomain.certificate_changeset(domain, %{
          certificate: "cert-data",
          private_key: "key-data",
          certificate_expires_at: expires_at,
          certificate_issued_at: DateTime.utc_now(),
          ssl_status: "issued",
          status: "active"
        })

      assert changeset.valid?
      assert get_change(changeset, :ssl_status) == "issued"
      assert get_change(changeset, :status) == "active"
    end
  end

  describe "ssl_error_changeset/2" do
    test "marks domain as ssl_failed with error message" do
      domain = %CustomDomain{error_count: 0}

      changeset = CustomDomain.ssl_error_changeset(domain, "ACME challenge failed")

      assert get_change(changeset, :ssl_status) == "failed"
      assert get_change(changeset, :status) == "ssl_failed"
      assert get_change(changeset, :last_error) == "ACME challenge failed"
      assert get_change(changeset, :error_count) == 1
    end

    test "increments error count" do
      domain = %CustomDomain{error_count: 2}

      changeset = CustomDomain.ssl_error_changeset(domain, "Another error")

      assert get_change(changeset, :error_count) == 3
    end
  end

  describe "suspend_changeset/2" do
    test "suspends domain with reason" do
      domain = %CustomDomain{status: "active"}

      changeset = CustomDomain.suspend_changeset(domain, "Abuse detected")

      assert get_change(changeset, :status) == "suspended"
      assert get_change(changeset, :last_error) == "Abuse detected"
    end
  end
end
