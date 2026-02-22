defmodule Elektrine.Accounts.TwoFactor do
  @moduledoc "Provides functionality for Two-Factor Authentication using TOTP.\n"
  alias NimbleTOTP
  @doc "Generates a new TOTP secret for a user.\n"
  def generate_secret do
    NimbleTOTP.secret()
  end

  @doc "Generates a new TOTP secret as a Base32 string for a user.\n"
  def generate_secret_base32 do
    generate_secret() |> secret_to_base32()
  end

  @doc "Generates a TOTP provisioning URI for QR code generation.\n"
  def generate_provisioning_uri(secret, username, issuer \\ "Elektrine") do
    NimbleTOTP.otpauth_uri("#{issuer}:#{username}", secret, issuer: issuer)
  end

  @doc "Converts a binary secret to Base32 encoding for manual entry in authenticator apps.\n"
  def secret_to_base32(secret) when is_binary(secret) do
    Base.encode32(secret, padding: false)
  end

  @doc "Generates a QR code PNG image as binary data for the given provisioning URI.\n"
  def generate_qr_code_png(provisioning_uri) when is_binary(provisioning_uri) do
    qr_code = EQRCode.encode(provisioning_uri)
    png_binary = EQRCode.png(qr_code, width: 200)
    {:ok, png_binary}
  rescue
    error -> {:error, error}
  end

  @doc "Generates a QR code as a base64 data URI for inline embedding in HTML.\nThis avoids timing issues with session cookies when using separate image requests.\n"
  def generate_qr_code_data_uri(provisioning_uri) when is_binary(provisioning_uri) do
    qr_code = EQRCode.encode(provisioning_uri)
    png_binary = EQRCode.png(qr_code, width: 200)
    base64_png = Base.encode64(png_binary)
    {:ok, "data:image/png;base64,#{base64_png}"}
  rescue
    error -> {:error, error}
  end

  @doc "Verifies a TOTP code against the user's secret.\n\nTOTP Configuration:\n- Algorithm: SHA1 (TOTP standard)\n- Digits: 6\n- Period: 30 seconds\n- Custom window: checks ±10 time periods manually\n\nUses ±1 period (±30 seconds) for a total 90-second validation window.\nThis handles minor clock drift while maintaining security.\n"
  def verify_totp(secret, code) when is_binary(secret) and is_binary(code) do
    require Logger

    case Integer.parse(code) do
      {numeric_code, ""} when numeric_code >= 0 and numeric_code <= 999_999 ->
        formatted_code = String.pad_leading(code, 6, "0")
        current_time = System.system_time(:second)

        valid =
          Enum.any?(-1..1, fn offset ->
            time_for_offset = current_time + offset * 30
            expected_code = NimbleTOTP.verification_code(secret, time: time_for_offset)
            expected_code == formatted_code
          end)

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

  def verify_totp(_, _) do
    false
  end

  @doc "Generates backup codes for account recovery.\nReturns {plain_codes, hashed_codes} tuple.\nPlain codes should be shown to user once, hashed codes stored in database.\n"
  def generate_backup_codes(count \\ 8) do
    plain_codes = 1..count |> Enum.map(fn _ -> generate_backup_code() end)
    hashed_codes = Enum.map(plain_codes, &hash_backup_code/1)
    {plain_codes, hashed_codes}
  end

  @doc "Verifies a backup code against the user's stored backup codes.\nSupports both legacy plaintext codes and new hashed codes for backward compatibility.\nReturns {:ok, remaining_codes} if valid, {:error, :invalid} if not.\n"
  def verify_backup_code(backup_codes, code) when is_list(backup_codes) and is_binary(code) do
    formatted_code = String.upcase(String.trim(code))

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

  def verify_backup_code(_, _) do
    {:error, :invalid}
  end

  defp hash_backup_code(code) when is_binary(code) do
    Argon2.hash_pwd_salt(code)
  end

  defp verify_backup_code_match(code, stored_code)
       when is_binary(code) and is_binary(stored_code) do
    cond do
      String.match?(stored_code, ~r/^[A-Z0-9]{8}$/) -> code == stored_code
      String.starts_with?(stored_code, "$argon2") -> Argon2.verify_pass(code, stored_code)
      true -> false
    end
  end

  defp verify_backup_code_match(_, _) do
    false
  end

  defp generate_backup_code do
    chars = "ABCDEFGHIJKLMNPQRSTUVWXYZ123456789"
    chars_list = String.codepoints(chars)
    chars_count = length(chars_list)

    :crypto.strong_rand_bytes(8)
    |> :binary.bin_to_list()
    |> Enum.map_join("", fn byte -> Enum.at(chars_list, rem(byte, chars_count)) end)
  end
end
