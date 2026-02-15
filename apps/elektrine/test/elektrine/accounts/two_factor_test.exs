defmodule Elektrine.Accounts.TwoFactorTest do
  use ExUnit.Case, async: true

  alias Elektrine.Accounts.TwoFactor

  describe "generate_secret/0" do
    test "generates a binary secret" do
      secret = TwoFactor.generate_secret()

      assert is_binary(secret)
      assert String.length(secret) > 0
      # Should be raw binary data, not Base32
      refute String.match?(secret, ~r/^[A-Z2-7]+$/)
    end

    test "can convert secret to base32" do
      secret = TwoFactor.generate_secret()
      base32_secret = TwoFactor.secret_to_base32(secret)

      assert is_binary(base32_secret)
      assert String.length(base32_secret) > 0
      # Base32 should only contain A-Z and 2-7
      assert String.match?(base32_secret, ~r/^[A-Z2-7]+$/)
    end
  end

  describe "generate_qr_code_png/1" do
    test "generates a QR code PNG from provisioning URI" do
      secret = TwoFactor.generate_secret()
      provisioning_uri = TwoFactor.generate_provisioning_uri(secret, "testuser")

      assert {:ok, png_binary} = TwoFactor.generate_qr_code_png(provisioning_uri)
      assert is_binary(png_binary)
      assert String.length(png_binary) > 0
      # PNG files start with specific magic bytes
      assert String.starts_with?(png_binary, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    end

    test "handles empty string" do
      assert {:ok, _png} = TwoFactor.generate_qr_code_png("")
    end
  end

  describe "generate_provisioning_uri/2" do
    test "generates a valid OTP auth URI" do
      secret = TwoFactor.generate_secret()
      username = "testuser"

      uri = TwoFactor.generate_provisioning_uri(secret, username)

      assert String.starts_with?(uri, "otpauth://totp/")
      assert String.contains?(uri, "Elektrine:#{username}")
      assert String.contains?(uri, "secret=")
      assert String.contains?(uri, "issuer=Elektrine")
    end

    test "allows custom issuer" do
      secret = TwoFactor.generate_secret()
      username = "testuser"
      issuer = "CustomApp"

      uri = TwoFactor.generate_provisioning_uri(secret, username, issuer)

      assert String.contains?(uri, "issuer=#{issuer}")
    end
  end

  describe "verify_totp/2" do
    test "verifies valid TOTP codes" do
      secret = TwoFactor.generate_secret()

      # Generate current code
      code = NimbleTOTP.verification_code(secret)

      assert TwoFactor.verify_totp(secret, code) == true
    end

    test "rejects invalid codes" do
      secret = TwoFactor.generate_secret()

      assert TwoFactor.verify_totp(secret, "000000") == false
      assert TwoFactor.verify_totp(secret, "invalid") == false
      assert TwoFactor.verify_totp(secret, "") == false
    end

    test "handles nil inputs gracefully" do
      assert TwoFactor.verify_totp(nil, "123456") == false
      assert TwoFactor.verify_totp("secret", nil) == false
    end

    test "handles codes with leading zeros" do
      secret = TwoFactor.generate_secret()

      # Simulate a code with leading zeros
      assert TwoFactor.verify_totp(secret, "000123") == false
    end
  end

  describe "generate_backup_codes/1" do
    test "generates default number of backup codes" do
      {plain_codes, hashed_codes} = TwoFactor.generate_backup_codes()

      assert length(plain_codes) == 8
      assert length(hashed_codes) == 8

      Enum.each(plain_codes, fn code ->
        assert is_binary(code)
        assert String.length(code) == 8
        # Should only contain alphanumeric characters
        assert String.match?(code, ~r/^[A-Z0-9]+$/)
      end)
    end

    test "generates custom number of backup codes" do
      {plain_codes, _hashed_codes} = TwoFactor.generate_backup_codes(5)

      assert length(plain_codes) == 5
    end

    test "generates unique codes" do
      {plain_codes, _hashed_codes} = TwoFactor.generate_backup_codes(10)
      unique_codes = Enum.uniq(plain_codes)

      assert length(plain_codes) == length(unique_codes)
    end
  end

  describe "verify_totp_only/2" do
    test "accepts valid TOTP codes only" do
      secret = TwoFactor.generate_secret()

      # Generate current code
      valid_code = NimbleTOTP.verification_code(secret)

      # Create a User struct with 2FA enabled
      user = %Elektrine.Accounts.User{
        two_factor_enabled: true,
        two_factor_secret: Base.encode64(secret),
        two_factor_backup_codes: ["ABCD1234", "EFGH5678"]
      }

      # Valid TOTP code should work
      assert {:ok, :totp} = Elektrine.Accounts.verify_totp_only(user, valid_code)
    end

    test "rejects backup codes" do
      secret = TwoFactor.generate_secret()

      user = %Elektrine.Accounts.User{
        two_factor_enabled: true,
        two_factor_secret: Base.encode64(secret),
        two_factor_backup_codes: ["ABCD1234", "EFGH5678"]
      }

      # Backup codes should be rejected
      assert {:error, :invalid_code} = Elektrine.Accounts.verify_totp_only(user, "ABCD1234")
      assert {:error, :invalid_code} = Elektrine.Accounts.verify_totp_only(user, "EFGH5678")
    end

    test "rejects invalid codes" do
      secret = TwoFactor.generate_secret()

      user = %Elektrine.Accounts.User{
        two_factor_enabled: true,
        two_factor_secret: Base.encode64(secret),
        two_factor_backup_codes: ["ABCD1234"]
      }

      # Invalid codes should be rejected
      assert {:error, :invalid_code} = Elektrine.Accounts.verify_totp_only(user, "000000")
      assert {:error, :invalid_code} = Elektrine.Accounts.verify_totp_only(user, "invalid")
    end

    test "rejects when 2FA is not enabled" do
      user = %Elektrine.Accounts.User{two_factor_enabled: false}

      assert {:error, :two_factor_not_enabled} =
               Elektrine.Accounts.verify_totp_only(user, "123456")
    end
  end

  describe "verify_backup_code/2" do
    test "verifies valid backup codes" do
      codes = ["ABCD1234", "EFGH5678", "IJKL9012"]

      assert {:ok, remaining} = TwoFactor.verify_backup_code(codes, "ABCD1234")
      assert length(remaining) == 2
      refute "ABCD1234" in remaining
    end

    test "handles case-insensitive codes" do
      codes = ["ABCD1234"]

      assert {:ok, _} = TwoFactor.verify_backup_code(codes, "abcd1234")
      assert {:ok, _} = TwoFactor.verify_backup_code(codes, " ABCD1234 ")
    end

    test "rejects invalid codes" do
      codes = ["ABCD1234", "EFGH5678"]

      assert {:error, :invalid} = TwoFactor.verify_backup_code(codes, "INVALID")
      assert {:error, :invalid} = TwoFactor.verify_backup_code(codes, "")
    end

    test "handles empty code list" do
      assert {:error, :invalid} = TwoFactor.verify_backup_code([], "ABCD1234")
    end

    test "handles nil inputs" do
      assert {:error, :invalid} = TwoFactor.verify_backup_code(nil, "ABCD1234")
      assert {:error, :invalid} = TwoFactor.verify_backup_code(["ABCD1234"], nil)
    end
  end
end
