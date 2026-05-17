defmodule Elektrine.Platform.RuntimeConfigValidatorTest do
  use ExUnit.Case, async: true

  alias Elektrine.Platform.RuntimeConfigValidator

  @encryption_error "production requires ENCRYPTION_MASTER_SECRET, ENCRYPTION_KEY_SALT, and ENCRYPTION_SEARCH_SALT, or ELEKTRINE_MASTER_SECRET; set ELEKTRINE_ALLOW_UNENCRYPTED_PROD_DATA=true only if unencrypted production data is intentional"

  @prod_encryption_env %{
    "ENCRYPTION_MASTER_SECRET" => "encryption-master-secret-with-enough-length",
    "ENCRYPTION_KEY_SALT" => "encryption-key-salt",
    "ENCRYPTION_SEARCH_SALT" => "encryption-search-salt"
  }

  test "allows deployments with no enabled optional modules" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env: %{},
               compiled_modules: [],
               enabled_modules: [],
               environment: :dev
             )
  end

  test "requires email service and domain config when email is enabled" do
    assert {:error, errors} =
             RuntimeConfigValidator.validate(
               env: %{},
               enabled_modules: [:email],
               environment: :prod
             )

    assert "production requires SESSION_SIGNING_SALT or ELEKTRINE_MASTER_SECRET so LiveView and cookie sessions stay consistent across instances" in errors

    assert "production requires SESSION_ENCRYPTION_SALT or ELEKTRINE_MASTER_SECRET so cookie sessions can be decrypted consistently across instances" in errors

    assert @encryption_error in errors

    assert "email module requires PRIMARY_DOMAIN" in errors
    assert "email module requires HARAKA_BASE_URL" in errors
  end

  test "requires Haraka credentials when email is enabled" do
    assert {:error, errors} =
             RuntimeConfigValidator.validate(
               env:
                 Map.merge(@prod_encryption_env, %{
                   "PRIMARY_DOMAIN" => "example.com",
                   "SESSION_SIGNING_SALT" => "signing-salt-16+",
                   "SESSION_ENCRYPTION_SALT" => "encryption-salt-16+"
                 }),
               enabled_modules: [:email],
               environment: :prod
             )

    assert "email module requires HARAKA_BASE_URL" in errors

    assert "email module requires one of HARAKA_HTTP_API_KEY, HARAKA_OUTBOUND_API_KEY, HARAKA_API_KEY, INTERNAL_API_KEY or ELEKTRINE_MASTER_SECRET" in errors

    assert "email module requires one of PHOENIX_API_KEY, HARAKA_INBOUND_API_KEY, HARAKA_API_KEY, INTERNAL_API_KEY or ELEKTRINE_MASTER_SECRET" in errors
  end

  test "requires either fleet bootstrap or self-hosted wireguard credentials when vpn is enabled" do
    assert {:error, errors} =
             RuntimeConfigValidator.validate(
               env: %{},
               enabled_modules: [:vpn],
               environment: :prod
             )

    assert "production requires SESSION_SIGNING_SALT or ELEKTRINE_MASTER_SECRET so LiveView and cookie sessions stay consistent across instances" in errors

    assert "production requires SESSION_ENCRYPTION_SALT or ELEKTRINE_MASTER_SECRET so cookie sessions can be decrypted consistently across instances" in errors

    assert @encryption_error in errors

    assert "vpn module requires either VPN_FLEET_REGISTRATION_KEY or self-hosted WireGuard credentials via VPN_SELFHOST_PRIVATE_KEY/VPN_SELFHOST_PUBLIC_KEY; set VPN_SELFHOST_ENDPOINT_HOST or VPN_SELFHOST_PUBLIC_IP to avoid endpoint autodetection" in errors
  end

  test "ignores disabled modules even when they are compiled" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env: %{},
               compiled_modules: [:email, :vpn],
               enabled_modules: [],
               environment: :dev
             )
  end

  test "accepts valid email and vpn configuration" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env:
                 Map.merge(@prod_encryption_env, %{
                   "PRIMARY_DOMAIN" => "example.com",
                   "SESSION_SIGNING_SALT" => "signing-salt-16+",
                   "SESSION_ENCRYPTION_SALT" => "encryption-salt-16+",
                   "HARAKA_BASE_URL" => "https://mail.example.com",
                   "HARAKA_HTTP_API_KEY" => "outbound-key-with-enough-length",
                   "PHOENIX_API_KEY" => "inbound-key-with-enough-length",
                   "VPN_FLEET_REGISTRATION_KEY" => "fleet-key"
                 }),
               enabled_modules: [:email, :vpn],
               environment: :prod
             )
  end

  test "accepts self-hosted wireguard configuration without a fleet key" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env:
                 Map.merge(@prod_encryption_env, %{
                   "SESSION_SIGNING_SALT" => "signing-salt-16+",
                   "SESSION_ENCRYPTION_SALT" => "encryption-salt-16+",
                   "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.10",
                   "VPN_SELFHOST_PRIVATE_KEY" => "server-private-key"
                 }),
               enabled_modules: [:vpn],
               environment: :prod
             )
  end

  test "accepts internal api key as shared Haraka credential" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env:
                 Map.merge(@prod_encryption_env, %{
                   "PRIMARY_DOMAIN" => "example.com",
                   "SESSION_SIGNING_SALT" => "signing-salt-16+",
                   "SESSION_ENCRYPTION_SALT" => "encryption-salt-16+",
                   "HARAKA_BASE_URL" => "https://mail.example.com",
                   "INTERNAL_API_KEY" => "shared-internal-key-with-enough-length"
                 }),
               enabled_modules: [:email],
               environment: :prod
             )
  end

  test "requires production encryption secrets unless unencrypted data is explicit" do
    assert {:error, errors} =
             RuntimeConfigValidator.validate(
               env: %{
                 "SESSION_SIGNING_SALT" => "signing-salt-16+",
                 "SESSION_ENCRYPTION_SALT" => "encryption-salt-16+"
               },
               enabled_modules: [],
               environment: :prod
             )

    assert @encryption_error in errors

    assert :ok =
             RuntimeConfigValidator.validate(
               env: %{
                 "SESSION_SIGNING_SALT" => "signing-salt-16+",
                 "SESSION_ENCRYPTION_SALT" => "encryption-salt-16+",
                 "ELEKTRINE_ALLOW_UNENCRYPTED_PROD_DATA" => "true"
               },
               enabled_modules: [],
               environment: :prod
             )
  end

  test "accepts master secret as source for derived session and Haraka secrets" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env: %{
                 "PRIMARY_DOMAIN" => "example.com",
                 "HARAKA_BASE_URL" => "https://mail.example.com",
                 "ELEKTRINE_MASTER_SECRET" => "master-secret-with-at-least-thirty-two-chars"
               },
               enabled_modules: [:email],
               environment: :prod
             )
  end

  test "rejects production placeholder secrets" do
    assert {:error, errors} =
             RuntimeConfigValidator.validate(
               env: %{
                 "DB_PASSWORD" => "change-me",
                 "ELEKTRINE_MASTER_SECRET" => "replace-with-long-random-secret"
               },
               enabled_modules: [],
               environment: :prod
             )

    assert "production secret DB_PASSWORD uses a known placeholder value" in errors
    assert "production secret ELEKTRINE_MASTER_SECRET uses a known placeholder value" in errors
  end

  test "rejects short production root secrets" do
    assert {:error, errors} =
             RuntimeConfigValidator.validate(
               env: %{"ELEKTRINE_MASTER_SECRET" => "too-short"},
               enabled_modules: [],
               environment: :prod
             )

    assert "production secret ELEKTRINE_MASTER_SECRET must be at least 32 characters" in errors
  end

  test "does not require production session salts outside prod" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env: %{},
               enabled_modules: [],
               environment: :dev
             )
  end
end
