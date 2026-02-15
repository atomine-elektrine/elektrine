defmodule Elektrine.CustomDomainsTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.CustomDomains
  alias Elektrine.CustomDomains.CustomDomain
  alias Elektrine.AccountsFixtures

  describe "count_user_domains/1" do
    test "returns 0 for user with no domains" do
      user = AccountsFixtures.user_fixture()
      assert CustomDomains.count_user_domains(user.id) == 0
    end

    test "returns correct count" do
      user = AccountsFixtures.user_fixture()
      {:ok, _} = CustomDomains.add_domain(user.id, "count-test.com")

      assert CustomDomains.count_user_domains(user.id) == 1
    end
  end

  describe "add_domain/2" do
    test "creates a custom domain for a user" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, %CustomDomain{} = domain} =
               CustomDomains.add_domain(user.id, "example-test.com")

      assert domain.domain == "example-test.com"
      assert domain.user_id == user.id
      assert domain.status == "pending_verification"
      assert domain.verification_token != nil
    end

    test "normalizes domain to lowercase" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, domain} = CustomDomains.add_domain(user.id, "EXAMPLE-TEST.COM")
      assert domain.domain == "example-test.com"
    end

    test "rejects invalid domain formats" do
      user = AccountsFixtures.user_fixture()

      assert {:error, changeset} = CustomDomains.add_domain(user.id, "not-a-domain")
      assert "must be a valid domain name" in errors_on(changeset).domain
    end

    test "rejects reserved domains" do
      user = AccountsFixtures.user_fixture()

      assert {:error, changeset} = CustomDomains.add_domain(user.id, "test.z.org")
      assert "is a reserved domain and cannot be used" in errors_on(changeset).domain

      assert {:error, changeset} = CustomDomains.add_domain(user.id, "elektrine.com")
      assert "is a reserved domain and cannot be used" in errors_on(changeset).domain
    end

    test "enforces domain limit per user" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, _} = CustomDomains.add_domain(user.id, "first-domain.com")

      assert {:error, :domain_limit_reached} =
               CustomDomains.add_domain(user.id, "second-domain.com")
    end

    test "enforces unique domains across users" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      assert {:ok, _} = CustomDomains.add_domain(user1.id, "unique-domain.com")
      assert {:error, changeset} = CustomDomains.add_domain(user2.id, "unique-domain.com")
      assert "is already registered" in errors_on(changeset).domain
    end
  end

  describe "get_domain/1" do
    test "returns domain by hostname" do
      user = AccountsFixtures.user_fixture()
      {:ok, created_domain} = CustomDomains.add_domain(user.id, "my-domain.com")

      domain = CustomDomains.get_domain("my-domain.com")
      assert domain.id == created_domain.id
    end

    test "returns nil for non-existent domain" do
      assert CustomDomains.get_domain("nonexistent.com") == nil
    end

    test "is case-insensitive" do
      user = AccountsFixtures.user_fixture()
      {:ok, _} = CustomDomains.add_domain(user.id, "my-domain.com")

      assert CustomDomains.get_domain("MY-DOMAIN.COM") != nil
    end
  end

  describe "list_user_domains/1" do
    test "returns all domains for a user" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "user-domain.com")

      domains = CustomDomains.list_user_domains(user.id)
      assert length(domains) == 1
      assert hd(domains).id == domain.id
    end

    test "returns empty list for user with no domains" do
      user = AccountsFixtures.user_fixture()
      assert CustomDomains.list_user_domains(user.id) == []
    end
  end

  describe "delete_domain/2" do
    test "deletes a domain by ID for a user" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "delete-me.com")

      assert {:ok, _} = CustomDomains.delete_domain(user.id, domain.id)
      assert CustomDomains.get_domain("delete-me.com") == nil
    end

    test "returns error when domain doesn't belong to user" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user1.id, "not-yours.com")

      assert {:error, :not_found} = CustomDomains.delete_domain(user2.id, domain.id)
    end
  end

  describe "get_verification_instructions/1" do
    test "returns DNS instructions for domain" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "instructions-test.com")

      instructions = CustomDomains.get_verification_instructions(domain)

      assert instructions.dns_record.type == "TXT"
      assert instructions.dns_record.name == "_elektrine"
      assert instructions.dns_record.value == "elektrine-verify=#{domain.verification_token}"
      assert instructions.a_record.type == "A"
      assert instructions.full_txt_hostname == "_elektrine.instructions-test.com"
    end
  end

  describe "get_active_domain/1" do
    test "returns nil for pending domain" do
      user = AccountsFixtures.user_fixture()
      {:ok, _} = CustomDomains.add_domain(user.id, "pending-domain.com")

      assert CustomDomains.get_active_domain("pending-domain.com") == nil
    end

    test "returns domain when status is active and ssl is issued" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "active-domain.com")

      # Manually update to active status (normally done by ACME flow)
      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued"})
        |> Elektrine.Repo.update()

      active = CustomDomains.get_active_domain("active-domain.com")
      assert active != nil
      assert active.domain == "active-domain.com"
    end

    test "preloads user association" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "preload-test.com")

      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued"})
        |> Elektrine.Repo.update()

      active = CustomDomains.get_active_domain("preload-test.com")
      assert active.user.id == user.id
    end

    test "is case-insensitive" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "case-test.com")

      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued"})
        |> Elektrine.Repo.update()

      assert CustomDomains.get_active_domain("CASE-TEST.COM") != nil
    end
  end

  describe "get_domain!/1" do
    test "returns domain by ID" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "get-by-id.com")

      fetched = CustomDomains.get_domain!(domain.id)
      assert fetched.id == domain.id
      assert fetched.domain == "get-by-id.com"
    end

    test "raises for non-existent ID" do
      assert_raise Ecto.NoResultsError, fn ->
        CustomDomains.get_domain!(999_999)
      end
    end
  end

  describe "verified?/1" do
    test "returns true for verified status" do
      domain = %CustomDomain{status: "verified"}
      assert CustomDomains.verified?(domain)
    end

    test "returns true for provisioning_ssl status" do
      domain = %CustomDomain{status: "provisioning_ssl"}
      assert CustomDomains.verified?(domain)
    end

    test "returns true for active status" do
      domain = %CustomDomain{status: "active"}
      assert CustomDomains.verified?(domain)
    end

    test "returns false for pending_verification status" do
      domain = %CustomDomain{status: "pending_verification"}
      refute CustomDomains.verified?(domain)
    end

    test "returns false for verification_failed status" do
      domain = %CustomDomain{status: "verification_failed"}
      refute CustomDomains.verified?(domain)
    end
  end

  describe "store_acme_challenge/3" do
    test "stores challenge token and response" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "challenge-test.com")

      assert {:ok, updated} =
               CustomDomains.store_acme_challenge(domain, "test-token", "test-response")

      assert updated.acme_challenge_token == "test-token"
      assert updated.acme_challenge_response == "test-response"
    end
  end

  describe "get_acme_challenge_response/1" do
    test "returns response for stored token" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "acme-response.com")
      {:ok, _} = CustomDomains.store_acme_challenge(domain, "lookup-token", "lookup-response")

      assert CustomDomains.get_acme_challenge_response("lookup-token") == "lookup-response"
    end

    test "returns nil for non-existent token" do
      assert CustomDomains.get_acme_challenge_response("nonexistent-token") == nil
    end
  end

  describe "provision_ssl/1" do
    test "returns error for non-verified domain" do
      domain = %CustomDomain{status: "pending_verification"}

      assert {:error, :not_verified} = CustomDomains.provision_ssl(domain)
    end

    test "updates status and queues job for verified domain" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "provision-test.com")

      # Update to verified status
      {:ok, verified_domain} =
        domain
        |> Ecto.Changeset.change(%{status: "verified"})
        |> Elektrine.Repo.update()

      assert {:ok, updated} = CustomDomains.provision_ssl(verified_domain)
      assert updated.status == "provisioning_ssl"
      assert updated.ssl_status == "provisioning"
    end
  end

  describe "mark_ssl_failed/2" do
    test "marks domain as failed with error message" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "fail-test.com")

      assert {:ok, failed} = CustomDomains.mark_ssl_failed(domain, "ACME error")
      assert failed.ssl_status == "failed"
      assert failed.status == "ssl_failed"
      assert failed.last_error == "ACME error"
      assert failed.error_count == 1
    end
  end

  describe "get_domains_needing_renewal/0" do
    test "returns domains with expiring certificates" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "renewal-test.com")

      # Set domain to active with certificate expiring in 20 days
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(20 * 24 * 60 * 60)
        |> DateTime.truncate(:second)

      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{
          status: "active",
          ssl_status: "issued",
          certificate_expires_at: expires_at
        })
        |> Elektrine.Repo.update()

      domains = CustomDomains.get_domains_needing_renewal()
      domain_names = Enum.map(domains, & &1.domain)

      assert "renewal-test.com" in domain_names
    end

    test "does not return domains with valid certificates" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "valid-cert.com")

      # Set domain to active with certificate expiring in 60 days
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(60 * 24 * 60 * 60)
        |> DateTime.truncate(:second)

      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{
          status: "active",
          ssl_status: "issued",
          certificate_expires_at: expires_at
        })
        |> Elektrine.Repo.update()

      domains = CustomDomains.get_domains_needing_renewal()
      domain_names = Enum.map(domains, & &1.domain)

      refute "valid-cert.com" in domain_names
    end
  end

  describe "delete_domain/1" do
    test "deletes domain struct" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "struct-delete.com")

      assert {:ok, _} = CustomDomains.delete_domain(domain)
      assert CustomDomains.get_domain("struct-delete.com") == nil
    end
  end

  # Email Support Tests

  describe "enable_email/1" do
    test "enables email for an active domain" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "email-enable.com")

      # Make domain active first
      {:ok, active_domain} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued"})
        |> Elektrine.Repo.update()

      assert {:ok, updated} = CustomDomains.enable_email(active_domain)
      assert updated.email_enabled == true
      assert updated.dkim_private_key != nil
      assert updated.dkim_public_key != nil
      assert updated.dkim_selector == "elektrine"
    end

    test "returns error for non-active domain" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "pending-email.com")

      assert {:error, :domain_not_active} = CustomDomains.enable_email(domain)
    end
  end

  describe "disable_email/1" do
    test "disables email and clears DNS verification" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "disable-email.com")

      # Make domain active and enable email
      {:ok, active_domain} =
        domain
        |> Ecto.Changeset.change(%{
          status: "active",
          ssl_status: "issued",
          email_enabled: true,
          mx_verified: true,
          spf_verified: true,
          dkim_verified: true
        })
        |> Elektrine.Repo.update()

      assert {:ok, updated} = CustomDomains.disable_email(active_domain)
      assert updated.email_enabled == false
      assert updated.mx_verified == false
      assert updated.spf_verified == false
      assert updated.dkim_verified == false
    end
  end

  describe "email_ready?/1" do
    test "returns true when all email requirements are met" do
      domain = %CustomDomain{
        status: "active",
        email_enabled: true,
        mx_verified: true,
        spf_verified: true,
        dkim_verified: true,
        dkim_private_key: "some-key"
      }

      assert CustomDomains.email_ready?(domain)
    end

    test "returns false when email is not enabled" do
      domain = %CustomDomain{
        status: "active",
        email_enabled: false,
        mx_verified: true,
        spf_verified: true,
        dkim_verified: true
      }

      refute CustomDomains.email_ready?(domain)
    end

    test "returns false when DNS records are not verified" do
      domain = %CustomDomain{
        status: "active",
        email_enabled: true,
        mx_verified: false,
        spf_verified: true,
        dkim_verified: true,
        dkim_private_key: "some-key"
      }

      refute CustomDomains.email_ready?(domain)
    end
  end

  describe "add_address/4" do
    setup do
      user = AccountsFixtures.user_fixture()
      # User fixture already creates a mailbox, so get it
      mailbox = Elektrine.Email.get_user_mailbox(user.id)
      {:ok, domain} = CustomDomains.add_domain(user.id, "address-test.com")

      {:ok, active_domain} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued", email_enabled: true})
        |> Elektrine.Repo.update()

      {:ok, user: user, mailbox: mailbox, domain: active_domain}
    end

    test "creates a custom domain address", %{mailbox: mailbox, domain: domain} do
      assert {:ok, address} =
               CustomDomains.add_address(domain, "hello", mailbox.id, "Main contact")

      assert address.local_part == "hello"
      assert address.mailbox_id == mailbox.id
      assert address.description == "Main contact"
      assert address.enabled == true
    end

    test "normalizes local part to lowercase", %{mailbox: mailbox, domain: domain} do
      assert {:ok, address} = CustomDomains.add_address(domain, "HELLO", mailbox.id)
      assert address.local_part == "hello"
    end

    test "prevents duplicate addresses", %{mailbox: mailbox, domain: domain} do
      assert {:ok, _} = CustomDomains.add_address(domain, "hello", mailbox.id)
      assert {:error, changeset} = CustomDomains.add_address(domain, "hello", mailbox.id)
      # The unique constraint error appears on the composite unique index
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :custom_domain_id) or Map.has_key?(errors, :local_part)
    end

    test "rejects reserved local parts", %{mailbox: mailbox, domain: domain} do
      assert {:error, changeset} = CustomDomains.add_address(domain, "postmaster", mailbox.id)
      assert "is a reserved address" in errors_on(changeset).local_part
    end
  end

  describe "find_mailbox_for_email/1" do
    setup do
      user = AccountsFixtures.user_fixture()
      # User fixture already creates a mailbox, so get it
      mailbox = Elektrine.Email.get_user_mailbox(user.id)
      {:ok, domain} = CustomDomains.add_domain(user.id, "find-mailbox.com")

      {:ok, active_domain} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued", email_enabled: true})
        |> Elektrine.Repo.update()

      {:ok, user: user, mailbox: mailbox, domain: active_domain}
    end

    test "finds mailbox by custom domain address", %{mailbox: mailbox, domain: domain} do
      # Use "hello" instead of "contact" which is reserved
      {:ok, _} = CustomDomains.add_address(domain, "hello", mailbox.id)

      assert {:ok, found_mailbox_id} =
               CustomDomains.find_mailbox_for_email("hello@find-mailbox.com")

      assert found_mailbox_id == mailbox.id
    end

    test "returns error for non-existent address", %{} do
      assert {:error, :not_found} =
               CustomDomains.find_mailbox_for_email("unknown@find-mailbox.com")
    end

    test "finds mailbox via catch-all", %{mailbox: mailbox, domain: domain} do
      # Enable catch-all
      {:ok, _} = CustomDomains.configure_catch_all(domain, mailbox.id, true)

      assert {:ok, found_mailbox_id} =
               CustomDomains.find_mailbox_for_email("anything@find-mailbox.com")

      assert found_mailbox_id == mailbox.id
    end
  end

  describe "configure_catch_all/3" do
    setup do
      user = AccountsFixtures.user_fixture()
      # User fixture already creates a mailbox, so get it
      mailbox = Elektrine.Email.get_user_mailbox(user.id)
      {:ok, domain} = CustomDomains.add_domain(user.id, "catchall.com")

      {:ok, active_domain} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued", email_enabled: true})
        |> Elektrine.Repo.update()

      {:ok, user: user, mailbox: mailbox, domain: active_domain}
    end

    test "enables catch-all", %{mailbox: mailbox, domain: domain} do
      assert {:ok, updated} = CustomDomains.configure_catch_all(domain, mailbox.id, true)
      assert updated.catch_all_enabled == true
      assert updated.catch_all_mailbox_id == mailbox.id
    end

    test "disables catch-all", %{mailbox: mailbox, domain: domain} do
      {:ok, enabled} = CustomDomains.configure_catch_all(domain, mailbox.id, true)
      assert {:ok, disabled} = CustomDomains.configure_catch_all(enabled, nil, false)
      assert disabled.catch_all_enabled == false
    end
  end

  describe "list_addresses/1" do
    setup do
      user = AccountsFixtures.user_fixture()
      # User fixture already creates a mailbox, so get it
      mailbox = Elektrine.Email.get_user_mailbox(user.id)
      {:ok, domain} = CustomDomains.add_domain(user.id, "list-addr.com")

      {:ok, active_domain} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued", email_enabled: true})
        |> Elektrine.Repo.update()

      {:ok, user: user, mailbox: mailbox, domain: active_domain}
    end

    test "returns all addresses for a domain", %{mailbox: mailbox, domain: domain} do
      # Use non-reserved local parts
      {:ok, _} = CustomDomains.add_address(domain, "hello", mailbox.id)
      {:ok, _} = CustomDomains.add_address(domain, "greetings", mailbox.id)

      addresses = CustomDomains.list_addresses(domain)
      local_parts = Enum.map(addresses, & &1.local_part)

      # Should be sorted alphabetically
      assert local_parts == ["greetings", "hello"]
    end
  end

  describe "custom_email_domain?/1" do
    test "returns true for email-enabled custom domain" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "custom-email.com")

      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued", email_enabled: true})
        |> Elektrine.Repo.update()

      assert CustomDomains.custom_email_domain?("custom-email.com")
    end

    test "returns false for domain without email" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "no-email.com")

      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued"})
        |> Elektrine.Repo.update()

      refute CustomDomains.custom_email_domain?("no-email.com")
    end

    test "returns false for non-existent domain" do
      refute CustomDomains.custom_email_domain?("nonexistent-domain.com")
    end
  end

  describe "list_email_enabled_domain_names/0" do
    test "returns list of domain names as strings" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain1} = CustomDomains.add_domain(user.id, "haraka-test1.com")

      {:ok, _} =
        domain1
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued", email_enabled: true})
        |> Elektrine.Repo.update()

      # Create another user for second domain (users are limited to 1 domain)
      user2 = AccountsFixtures.user_fixture()
      {:ok, domain2} = CustomDomains.add_domain(user2.id, "haraka-test2.com")

      {:ok, _} =
        domain2
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued", email_enabled: true})
        |> Elektrine.Repo.update()

      domains = CustomDomains.list_email_enabled_domain_names()

      assert is_list(domains)
      assert "haraka-test1.com" in domains
      assert "haraka-test2.com" in domains
    end

    test "excludes domains without email enabled" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "no-email-haraka.com")

      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued", email_enabled: false})
        |> Elektrine.Repo.update()

      domains = CustomDomains.list_email_enabled_domain_names()

      refute "no-email-haraka.com" in domains
    end

    test "excludes inactive domains" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = CustomDomains.add_domain(user.id, "inactive-haraka.com")

      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{status: "pending", ssl_status: "issued", email_enabled: true})
        |> Elektrine.Repo.update()

      domains = CustomDomains.list_email_enabled_domain_names()

      refute "inactive-haraka.com" in domains
    end
  end
end
