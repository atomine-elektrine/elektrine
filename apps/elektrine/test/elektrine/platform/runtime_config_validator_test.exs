defmodule Elektrine.Platform.RuntimeConfigValidatorTest do
  use ExUnit.Case, async: true

  alias Elektrine.Platform.RuntimeConfigValidator

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

    assert "production requires SESSION_SIGNING_SALT or ELEKTRINE_MASTER_SECRET (SECRET_KEY_BASE also works) so LiveView and cookie sessions stay consistent across instances" in errors

    assert "production requires SESSION_ENCRYPTION_SALT or ELEKTRINE_MASTER_SECRET (SECRET_KEY_BASE also works) so cookie sessions can be decrypted consistently across instances" in errors

    assert "email module requires PRIMARY_DOMAIN" in errors
    assert "email module requires HARAKA_BASE_URL" in errors
  end

  test "requires Haraka credentials when email is enabled" do
    assert {:error, errors} =
             RuntimeConfigValidator.validate(
               env: %{
                 "PRIMARY_DOMAIN" => "example.com",
                 "SESSION_SIGNING_SALT" => "signing-salt",
                 "SESSION_ENCRYPTION_SALT" => "encryption-salt"
               },
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

    assert "production requires SESSION_SIGNING_SALT or ELEKTRINE_MASTER_SECRET (SECRET_KEY_BASE also works) so LiveView and cookie sessions stay consistent across instances" in errors

    assert "production requires SESSION_ENCRYPTION_SALT or ELEKTRINE_MASTER_SECRET (SECRET_KEY_BASE also works) so cookie sessions can be decrypted consistently across instances" in errors

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
               env: %{
                 "PRIMARY_DOMAIN" => "example.com",
                 "SESSION_SIGNING_SALT" => "signing-salt",
                 "SESSION_ENCRYPTION_SALT" => "encryption-salt",
                 "HARAKA_BASE_URL" => "https://mail.example.com",
                 "HARAKA_HTTP_API_KEY" => "outbound-key",
                 "PHOENIX_API_KEY" => "inbound-key",
                 "VPN_FLEET_REGISTRATION_KEY" => "fleet-key"
               },
               enabled_modules: [:email, :vpn],
               environment: :prod
             )
  end

  test "accepts self-hosted wireguard configuration without a fleet key" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env: %{
                 "SESSION_SIGNING_SALT" => "signing-salt",
                 "SESSION_ENCRYPTION_SALT" => "encryption-salt",
                 "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.10",
                 "VPN_SELFHOST_PRIVATE_KEY" => "server-private-key"
               },
               enabled_modules: [:vpn],
               environment: :prod
             )
  end

  test "accepts internal api key as shared Haraka credential" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env: %{
                 "PRIMARY_DOMAIN" => "example.com",
                 "SESSION_SIGNING_SALT" => "signing-salt",
                 "SESSION_ENCRYPTION_SALT" => "encryption-salt",
                 "HARAKA_BASE_URL" => "https://mail.example.com",
                 "INTERNAL_API_KEY" => "shared-internal-key"
               },
               enabled_modules: [:email],
               environment: :prod
             )
  end

  test "accepts master secret as source for derived session and Haraka secrets" do
    assert :ok =
             RuntimeConfigValidator.validate(
               env: %{
                 "PRIMARY_DOMAIN" => "example.com",
                 "HARAKA_BASE_URL" => "https://mail.example.com",
                 "ELEKTRINE_MASTER_SECRET" => "master-secret"
               },
               enabled_modules: [:email],
               environment: :prod
             )
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
