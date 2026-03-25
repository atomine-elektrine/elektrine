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

    assert "production requires SESSION_SIGNING_SALT so LiveView and cookie sessions stay consistent across instances" in errors

    assert "production requires SESSION_ENCRYPTION_SALT so cookie sessions can be decrypted consistently across instances" in errors

    assert "email module requires PRIMARY_DOMAIN" in errors
    assert "email module requires EMAIL_SERVICE=haraka" in errors
  end

  test "requires Haraka credentials when email uses Haraka" do
    assert {:error, errors} =
             RuntimeConfigValidator.validate(
               env: %{
                 "PRIMARY_DOMAIN" => "example.com",
                 "EMAIL_SERVICE" => "haraka",
                 "SESSION_SIGNING_SALT" => "signing-salt",
                 "SESSION_ENCRYPTION_SALT" => "encryption-salt"
               },
               enabled_modules: [:email],
               environment: :prod
             )

    assert "email module with EMAIL_SERVICE=haraka requires HARAKA_BASE_URL" in errors

    assert "email module with EMAIL_SERVICE=haraka requires one of HARAKA_HTTP_API_KEY, HARAKA_OUTBOUND_API_KEY, HARAKA_API_KEY" in errors

    assert "email module with EMAIL_SERVICE=haraka requires one of PHOENIX_API_KEY, HARAKA_INBOUND_API_KEY, HARAKA_API_KEY" in errors
  end

  test "requires a VPN fleet registration key when vpn is enabled" do
    assert {:error, errors} =
             RuntimeConfigValidator.validate(
               env: %{},
               enabled_modules: [:vpn],
               environment: :prod
             )

    assert "production requires SESSION_SIGNING_SALT so LiveView and cookie sessions stay consistent across instances" in errors

    assert "production requires SESSION_ENCRYPTION_SALT so cookie sessions can be decrypted consistently across instances" in errors

    assert "vpn module requires VPN_FLEET_REGISTRATION_KEY" in errors
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
                 "EMAIL_SERVICE" => "haraka",
                 "HARAKA_BASE_URL" => "https://mail.example.com",
                 "HARAKA_HTTP_API_KEY" => "outbound-key",
                 "PHOENIX_API_KEY" => "inbound-key",
                 "VPN_FLEET_REGISTRATION_KEY" => "fleet-key"
               },
               enabled_modules: [:email, :vpn],
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
