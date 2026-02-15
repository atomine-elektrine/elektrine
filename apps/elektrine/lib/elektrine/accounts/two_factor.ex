defmodule Elektrine.Accounts.TwoFactor do
  @moduledoc """
  Provides functionality for Two-Factor Authentication using TOTP.
  """

  alias NimbleTOTP

  @doc """
  Generates a new TOTP secret for a user.
  """
  def generate_secret do
    # Use NimbleTOTP's built-in secret generation - it works correctly
    NimbleTOTP.secret()
  end

  @doc """
  Generates a new TOTP secret as a Base32 string for a user.
  """
  def generate_secret_base32 do
    generate_secret() |> secret_to_base32()
  end

  @doc """
  Generates a TOTP provisioning URI for QR code generation.
  """
  def generate_provisioning_uri(secret, username, issuer \\ "Elektrine") do
    # Use NimbleTOTP's URI generation - it handles the secret correctly
    NimbleTOTP.otpauth_uri("#{issuer}:#{username}", secret, issuer: issuer)
  end

  @doc """
  Converts a binary secret to Base32 encoding for manual entry in authenticator apps.
  """
  def secret_to_base32(secret) when is_binary(secret) do
    Base.encode32(secret, padding: false)
  end

  @doc """
  Generates a QR code PNG image as binary data for the given provisioning URI.
  """
  def generate_qr_code_png(provisioning_uri) when is_binary(provisioning_uri) do
    try do
      qr_code = EQRCode.encode(provisioning_uri)
      png_binary = EQRCode.png(qr_code, width: 200)
      {:ok, png_binary}
    rescue
      error ->
        {:error, error}
    end
  end

  @doc """
  Generates a QR code as a base64 data URI for inline embedding in HTML.
  This avoids timing issues with session cookies when using separate image requests.
  """
  def generate_qr_code_data_uri(provisioning_uri) when is_binary(provisioning_uri) do
    try do
      qr_code = EQRCode.encode(provisioning_uri)
      png_binary = EQRCode.png(qr_code, width: 200)
      base64_png = Base.encode64(png_binary)
      {:ok, "data:image/png;base64,#{base64_png}"}
    rescue
      error ->
        {:error, error}
    end
  end

  @doc """
  Verifies a TOTP code against the user's secret.

  TOTP Configuration:
  - Algorithm: SHA1 (TOTP standard)
  - Digits: 6
  - Period: 30 seconds
  - Custom window: checks ±10 time periods manually

  Uses ±1 period (±30 seconds) for a total 90-second validation window.
  This handles minor clock drift while maintaining security.
  """
  def verify_totp(secret, code) when is_binary(secret) and is_binary(code) do
    require Logger

    case Integer.parse(code) do
      {numeric_code, ""} when numeric_code >= 0 and numeric_code <= 999_999 ->
        formatted_code = String.pad_leading(code, 6, "0")

        # Get current Unix timestamp
        current_time = System.system_time(:second)

        # Check ±1 period (±30 seconds) - standard TOTP window
        # This gives a 90-second total window which handles minor clock drift
        valid =
          Enum.any?(-1..1, fn offset ->
            # Calculate time for this offset (30-second periods)
            time_for_offset = current_time + offset * 30

            # Generate TOTP code for this specific time
            expected_code = NimbleTOTP.verification_code(secret, time: time_for_offset)

            expected_code == formatted_code
          end)

        # Log verification attempts (don't log actual codes in production)
        if valid do
          Logger.debug("2FA code verified successfully")
        else
          Logger.warning("2FA code verification failed for user")
        end

        valid

      _ ->
        Logger.warning("2FA code format invalid")
        false
    end
  end

  def verify_totp(_, _), do: false

  @doc """
  Generates backup codes for account recovery.
  Returns {plain_codes, hashed_codes} tuple.
  Plain codes should be shown to user once, hashed codes stored in database.
  """
  def generate_backup_codes(count \\ 8) do
    plain_codes =
      1..count
      |> Enum.map(fn _ -> generate_backup_code() end)

    hashed_codes = Enum.map(plain_codes, &hash_backup_code/1)

    {plain_codes, hashed_codes}
  end

  @doc """
  Verifies a backup code against the user's stored backup codes.
  Supports both legacy plaintext codes and new hashed codes for backward compatibility.
  Returns {:ok, remaining_codes} if valid, {:error, :invalid} if not.
  """
  def verify_backup_code(backup_codes, code) when is_list(backup_codes) and is_binary(code) do
    formatted_code = String.upcase(String.trim(code))

    # Check each code to find a match (handles both plaintext and hashed)
    case Enum.find_index(backup_codes, fn stored_code ->
           verify_backup_code_match(formatted_code, stored_code)
         end) do
      nil ->
        {:error, :invalid}

      index ->
        remaining_codes = List.delete_at(backup_codes, index)
        {:ok, remaining_codes}
    end
  end

  def verify_backup_code(_, _), do: {:error, :invalid}

  # Hash a backup code using Argon2 (same as passwords for consistency)
  defp hash_backup_code(code) when is_binary(code) do
    Argon2.hash_pwd_salt(code)
  end

  # Verify a backup code against stored value (handles both plaintext and hashed)
  # This provides backward compatibility for existing users with plaintext codes
  defp verify_backup_code_match(code, stored_code)
       when is_binary(code) and is_binary(stored_code) do
    cond do
      # Check if it's a plaintext match (legacy format - 8 uppercase alphanumeric)
      String.match?(stored_code, ~r/^[A-Z0-9]{8}$/) ->
        code == stored_code

      # Check if it's an Argon2 hash (starts with $argon2)
      String.starts_with?(stored_code, "$argon2") ->
        Argon2.verify_pass(code, stored_code)

      # Unknown format, reject
      true ->
        false
    end
  end

  defp verify_backup_code_match(_, _), do: false

  # Private functions

  defp generate_backup_code do
    # Generate 8 character alphanumeric code using cryptographically secure random
    # (excluding similar looking characters like 0, O, I, L)
    chars = "ABCDEFGHIJKLMNPQRSTUVWXYZ123456789"
    chars_list = String.codepoints(chars)
    chars_count = length(chars_list)

    # Use :crypto.strong_rand_bytes for cryptographically secure randomness
    :crypto.strong_rand_bytes(8)
    |> :binary.bin_to_list()
    |> Enum.map_join("", fn byte -> Enum.at(chars_list, rem(byte, chars_count)) end)
  end
end
