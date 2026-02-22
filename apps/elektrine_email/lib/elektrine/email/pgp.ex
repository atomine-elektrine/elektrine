defmodule Elektrine.Email.PGP do
  @moduledoc "PGP/OpenPGP support for email encryption.\n\nProvides:\n- Public key storage and retrieval\n- WKD (Web Key Directory) lookups\n- PGP encryption of outgoing emails\n- Key fingerprint extraction\n"
  alias Elektrine.Accounts.User
  alias Elektrine.Email.Contact
  alias Elektrine.Email.PgpKeyCache
  alias Elektrine.Repo
  import Ecto.Query
  import Bitwise
  require Logger
  @cache_ttl_found_hours 24
  @cache_ttl_not_found_hours 1
  @wkd_timeout 10_000
  @doc "Stores a user's PGP public key.\nParses the key to extract fingerprint and key ID.\nAccepts either a user struct or user_id.\n"
  def store_user_key(%User{id: user_id}, public_key_armor) do
    store_user_key(user_id, public_key_armor)
  end

  def store_user_key(user_id, public_key_armor) when is_binary(public_key_armor) do
    case parse_public_key(public_key_armor) do
      {:ok, key_info} ->
        user = Repo.get!(User, user_id)
        wkd_hash_value = wkd_hash(user.username)

        user
        |> Ecto.Changeset.change(%{
          pgp_public_key: public_key_armor,
          pgp_fingerprint: key_info.fingerprint,
          pgp_key_id: key_info.key_id,
          pgp_key_uploaded_at: DateTime.utc_now(),
          pgp_wkd_hash: wkd_hash_value
        })
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Removes a user's PGP public key.\nAccepts either a user struct or user_id.\n"
  def delete_user_key(%User{id: user_id}) do
    delete_user_key(user_id)
  end

  def delete_user_key(user_id) do
    remove_user_key(user_id)
  end

  def remove_user_key(user_id) do
    user = Repo.get!(User, user_id)

    user
    |> Ecto.Changeset.change(%{
      pgp_public_key: nil,
      pgp_fingerprint: nil,
      pgp_key_id: nil,
      pgp_key_uploaded_at: nil,
      pgp_wkd_hash: nil
    })
    |> Repo.update()
  end

  @doc "Gets a user's PGP public key by user ID.\n"
  def get_user_key(user_id) do
    case Repo.get(User, user_id) do
      %User{pgp_public_key: key} when not is_nil(key) -> {:ok, key}
      _ -> {:error, :no_key}
    end
  end

  @doc "Gets a user's PGP public key by email address.\nUsed for WKD responses.\n"
  def get_key_by_email(email) when is_binary(email) do
    clean_email = String.downcase(String.trim(email))
    [local_part, domain] = String.split(clean_email, "@")
    our_domains = ["elektrine.com", "z.org"]

    if domain in our_domains do
      case Repo.get_by(User, username: local_part) do
        %User{pgp_public_key: key} when not is_nil(key) -> {:ok, key}
        _ -> {:error, :no_key}
      end
    else
      {:error, :not_our_domain}
    end
  end

  @doc "Stores a PGP public key for a contact.\n"
  def store_contact_key(contact_id, public_key_armor, source \\ "manual") do
    case parse_public_key(public_key_armor) do
      {:ok, key_info} ->
        contact = Repo.get!(Contact, contact_id)

        contact
        |> Ecto.Changeset.change(%{
          pgp_public_key: public_key_armor,
          pgp_fingerprint: key_info.fingerprint,
          pgp_key_id: key_info.key_id,
          pgp_key_source: source,
          pgp_key_fetched_at: DateTime.utc_now()
        })
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Gets a contact's PGP public key.\n"
  def get_contact_key(contact_id) do
    case Repo.get(Contact, contact_id) do
      %Contact{pgp_public_key: key} when not is_nil(key) -> {:ok, key}
      _ -> {:error, :no_key}
    end
  end

  @doc "Looks up a PGP public key for an email address.\nFirst checks cache, then contacts, then WKD.\n"
  def lookup_key(email) when is_binary(email) do
    clean_email = String.downcase(String.trim(email))

    case get_cached_key(clean_email) do
      {:ok, key} ->
        {:ok, key}

      {:not_found, _} ->
        {:error, :no_key}

      :miss ->
        case lookup_wkd(clean_email) do
          {:ok, key} ->
            cache_key(clean_email, key, "wkd")
            {:ok, key}

          {:error, _reason} ->
            cache_not_found(clean_email)
            {:error, :no_key}
        end
    end
  end

  @doc "Looks up a recipient's key, checking user's contacts first.\n"
  def lookup_recipient_key(email, user_id) when is_binary(email) do
    clean_email = String.downcase(String.trim(email))

    case get_contact_key_by_email(clean_email, user_id) do
      {:ok, key} -> {:ok, key}
      {:error, :no_key} -> lookup_key(clean_email)
    end
  end

  defp get_contact_key_by_email(email, user_id) do
    query =
      from(c in Contact,
        where: c.user_id == ^user_id,
        where: c.email == ^email or fragment("? = ANY(?)", ^email, c.emails),
        where: not is_nil(c.pgp_public_key),
        select: c.pgp_public_key,
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :no_key}
      key -> {:ok, key}
    end
  end

  @doc "Performs a Web Key Directory (WKD) lookup for an email address.\nImplements the advanced method as per draft-koch-openpgp-webkey-service.\n"
  def lookup_wkd(email) when is_binary(email) do
    clean_email = String.downcase(String.trim(email))

    case String.split(clean_email, "@") do
      [local_part, domain] ->
        hash = wkd_hash(local_part)
        advanced_url = "https://openpgpkey.#{domain}/.well-known/openpgpkey/#{domain}/hu/#{hash}"
        direct_url = "https://#{domain}/.well-known/openpgpkey/hu/#{hash}"

        case fetch_wkd_key(advanced_url) do
          {:ok, key} ->
            Logger.info("WKD: Found key for #{email} via advanced method")
            {:ok, key}

          {:error, _} ->
            case fetch_wkd_key(direct_url) do
              {:ok, key} ->
                Logger.info("WKD: Found key for #{email} via direct method")
                {:ok, key}

              {:error, reason} ->
                Logger.debug("WKD: No key found for #{email}: #{inspect(reason)}")
                {:error, :not_found}
            end
        end

      _ ->
        {:error, :invalid_email}
    end
  end

  defp fetch_wkd_key(url) do
    headers = [{"Accept", "application/octet-stream"}, {"User-Agent", "Elektrine-WKD-Client/1.0"}]
    request = Finch.build(:get, url, headers)

    case Finch.request(request, Elektrine.Finch, receive_timeout: @wkd_timeout) do
      {:ok, %Finch.Response{status: 200, body: body}} when byte_size(body) > 0 ->
        armored = armor_public_key(body)
        {:ok, armored}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Computes the WKD hash for a local part.\nUses SHA-1 and z-base32 encoding as per the spec.\n"
  def wkd_hash(local_part) do
    local_part |> String.downcase() |> then(&:crypto.hash(:sha, &1)) |> zbase32_encode()
  end

  @zbase32_alphabet ~c"ybndrfg8ejkmcpqxot1uwisza345h769"
  defp zbase32_encode(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reduce({<<>>, 0, 0}, fn byte, {acc, buffer, bits} ->
      buffer = bor(buffer <<< 8, byte)
      bits = bits + 8
      {new_acc, new_buffer, new_bits} = extract_zbase32_chars(acc, buffer, bits)
      {new_acc, new_buffer, new_bits}
    end)
    |> then(fn {acc, buffer, bits} ->
      if bits > 0 do
        buffer = buffer <<< (5 - bits)
        char = Enum.at(@zbase32_alphabet, band(buffer, 31))
        acc <> <<char>>
      else
        acc
      end
    end)
  end

  defp extract_zbase32_chars(acc, buffer, bits) when bits >= 5 do
    index = band(bsr(buffer, bits - 5), 31)
    char = Enum.at(@zbase32_alphabet, index)
    extract_zbase32_chars(acc <> <<char>>, buffer, bits - 5)
  end

  defp extract_zbase32_chars(acc, buffer, bits) do
    {acc, buffer, bits}
  end

  defp get_cached_key(email) do
    query =
      from(c in PgpKeyCache, where: c.email == ^email, where: c.expires_at > ^DateTime.utc_now())

    case Repo.one(query) do
      nil -> :miss
      %PgpKeyCache{status: "found", public_key: key} -> {:ok, key}
      %PgpKeyCache{status: "not_found"} -> {:not_found, :cached}
      _ -> :miss
    end
  end

  defp cache_key(email, public_key, source) do
    case parse_public_key(public_key) do
      {:ok, key_info} ->
        expires_at = DateTime.add(DateTime.utc_now(), @cache_ttl_found_hours * 3600, :second)

        %PgpKeyCache{}
        |> PgpKeyCache.changeset(%{
          email: email,
          public_key: public_key,
          key_id: key_info.key_id,
          fingerprint: key_info.fingerprint,
          source: source,
          status: "found",
          expires_at: expires_at
        })
        |> Repo.insert(on_conflict: :replace_all, conflict_target: :email)

      {:error, _} ->
        expires_at = DateTime.add(DateTime.utc_now(), @cache_ttl_found_hours * 3600, :second)

        %PgpKeyCache{}
        |> PgpKeyCache.changeset(%{
          email: email,
          public_key: public_key,
          source: source,
          status: "found",
          expires_at: expires_at
        })
        |> Repo.insert(on_conflict: :replace_all, conflict_target: :email)
    end
  end

  defp cache_not_found(email) do
    expires_at = DateTime.add(DateTime.utc_now(), @cache_ttl_not_found_hours * 3600, :second)

    %PgpKeyCache{}
    |> PgpKeyCache.changeset(%{email: email, status: "not_found", expires_at: expires_at})
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :email)
  end

  @doc "Parses a PGP public key and extracts metadata.\nReturns {:ok, %{fingerprint: ..., key_id: ...}} or {:error, reason}\n"
  def parse_public_key(armor) when is_binary(armor) do
    if String.contains?(armor, "-----BEGIN PGP PUBLIC KEY BLOCK-----") do
      case extract_key_data(armor) do
        {:ok, binary_key} ->
          case extract_fingerprint(binary_key) do
            {:ok, fingerprint} ->
              key_id = String.slice(fingerprint, -16, 16)
              {:ok, %{fingerprint: fingerprint, key_id: key_id}}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_pgp_key}
    end
  end

  def parse_public_key(_) do
    {:error, :invalid_input}
  end

  defp extract_key_data(armor) do
    lines = String.split(armor, ~r/\r?\n/)

    content =
      lines
      |> Enum.drop_while(&(!String.starts_with?(&1, "-----BEGIN")))
      |> Enum.drop(1)
      |> Enum.take_while(&(!String.starts_with?(&1, "-----END")))
      |> Enum.reject(&(&1 == "" || String.starts_with?(&1, "=") || String.contains?(&1, ":")))
      |> Enum.join("")

    case Base.decode64(content) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  defp extract_fingerprint(binary_key) do
    case find_public_key_packet(binary_key) do
      {:ok, packet_content} ->
        packet_len = byte_size(packet_content)
        data_to_hash = <<153, packet_len::big-16>> <> packet_content
        fingerprint = :crypto.hash(:sha, data_to_hash) |> Base.encode16(case: :upper)
        {:ok, fingerprint}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :parse_error}
  end

  defp find_public_key_packet(binary) do
    parse_packets(binary)
  end

  defp parse_packets(<<>>) do
    {:error, :no_public_key_packet}
  end

  defp parse_packets(<<tag_byte, rest::binary>>) when band(tag_byte, 128) != 0 do
    if band(tag_byte, 64) != 0 do
      tag = band(tag_byte, 63)

      case parse_new_packet_length(rest) do
        {:ok, length, packet_rest} ->
          <<packet_content::binary-size(length), remaining::binary>> = packet_rest

          if tag == 6 do
            {:ok, packet_content}
          else
            parse_packets(remaining)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      tag = bsr(band(tag_byte, 60), 2)
      length_type = band(tag_byte, 3)

      case parse_old_packet_length(rest, length_type) do
        {:ok, length, packet_rest} ->
          <<packet_content::binary-size(length), remaining::binary>> = packet_rest

          if tag == 6 do
            {:ok, packet_content}
          else
            parse_packets(remaining)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_packets(_) do
    {:error, :invalid_packet_format}
  end

  defp parse_new_packet_length(<<len, rest::binary>>) when len < 192 do
    {:ok, len, rest}
  end

  defp parse_new_packet_length(<<first, second, rest::binary>>)
       when first >= 192 and first < 224 do
    len = ((first - 192) <<< 8) + second + 192
    {:ok, len, rest}
  end

  defp parse_new_packet_length(<<255, len::big-32, rest::binary>>) do
    {:ok, len, rest}
  end

  defp parse_new_packet_length(_) do
    {:error, :invalid_length}
  end

  defp parse_old_packet_length(<<len, rest::binary>>, 0) do
    {:ok, len, rest}
  end

  defp parse_old_packet_length(<<len::big-16, rest::binary>>, 1) do
    {:ok, len, rest}
  end

  defp parse_old_packet_length(<<len::big-32, rest::binary>>, 2) do
    {:ok, len, rest}
  end

  defp parse_old_packet_length(_, 3) do
    {:error, :indeterminate_length}
  end

  defp parse_old_packet_length(_, _) do
    {:error, :invalid_length}
  end

  @doc "Encrypts a message using the recipient's PGP public key.\nUses GPG command-line tool for encryption.\nReturns {:ok, encrypted_armor} or {:error, reason}\n"
  def encrypt(plaintext, public_key_armor)
      when is_binary(plaintext) and is_binary(public_key_armor) do
    key_file = System.tmp_dir!() |> Path.join("pgp_key_#{:rand.uniform(1_000_000)}.asc")
    input_file = System.tmp_dir!() |> Path.join("pgp_input_#{:rand.uniform(1_000_000)}.txt")
    keyring_dir = System.tmp_dir!() |> Path.join("pgp_keyring_#{:rand.uniform(1_000_000)}")

    try do
      File.write!(key_file, public_key_armor)
      File.write!(input_file, plaintext)
      File.mkdir_p!(keyring_dir)

      {_output, import_status} =
        System.cmd("gpg", ["--homedir", keyring_dir, "--batch", "--yes", "--import", key_file],
          stderr_to_stdout: true
        )

      if import_status != 0 do
        {:error, :key_import_failed}
      else
        {output, encrypt_status} =
          System.cmd(
            "gpg",
            [
              "--homedir",
              keyring_dir,
              "--batch",
              "--yes",
              "--trust-model",
              "always",
              "--armor",
              "--encrypt",
              "--recipient-file",
              key_file,
              input_file
            ],
            stderr_to_stdout: true
          )

        encrypted_file = input_file <> ".asc"

        if encrypt_status == 0 and File.exists?(encrypted_file) do
          encrypted = File.read!(encrypted_file)
          File.rm(encrypted_file)
          {:ok, encrypted}
        else
          Logger.error("PGP encryption failed: #{output}")
          {:error, :encryption_failed}
        end
      end
    rescue
      e ->
        Logger.error("PGP encryption error: #{inspect(e)}")
        {:error, :encryption_error}
    after
      File.rm(key_file)
      File.rm(input_file)
      File.rm(input_file <> ".asc")
      File.rm_rf(keyring_dir)
    end
  end

  @doc "Encrypts an email body for a recipient if they have a PGP key.\nReturns the email params with encrypted body, or unchanged if no key.\n"
  def maybe_encrypt_email(params, recipient_email, user_id) do
    case lookup_recipient_key(recipient_email, user_id) do
      {:ok, public_key} ->
        body_to_encrypt = params[:text_body] || params[:html_body] || ""

        if body_to_encrypt != "" do
          case encrypt(body_to_encrypt, public_key) do
            {:ok, encrypted} ->
              Logger.info("PGP: Encrypted email to #{recipient_email}")

              params
              |> Map.put(:text_body, encrypted)
              |> Map.put(:html_body, nil)
              |> Map.put(:pgp_encrypted, true)

            {:error, reason} ->
              Logger.warning(
                "PGP: Failed to encrypt email to #{recipient_email}: #{inspect(reason)}"
              )

              params
          end
        else
          params
        end

      {:error, _} ->
        params
    end
  end

  @doc "Converts binary key data to ASCII armor format.\n"
  def armor_public_key(binary_key) when is_binary(binary_key) do
    encoded = Base.encode64(binary_key, padding: true)

    lines =
      encoded |> String.graphemes() |> Enum.chunk_every(64) |> Enum.map_join("\n", &Enum.join/1)

    checksum = crc24(binary_key)
    checksum_encoded = Base.encode64(<<checksum::big-24>>)
    "-----BEGIN PGP PUBLIC KEY BLOCK-----

#{lines}
=#{checksum_encoded}
-----END PGP PUBLIC KEY BLOCK-----
"
  end

  @crc24_init 11_994_318
  @crc24_poly 25_578_747
  defp crc24(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.reduce(@crc24_init, fn byte, crc ->
      crc = bxor(crc, byte <<< 16)

      Enum.reduce(0..7, crc, fn _, acc ->
        acc = acc <<< 1

        if band(acc, 16_777_216) != 0 do
          bxor(acc, @crc24_poly)
        else
          acc
        end
      end)
    end)
    |> band(16_777_215)
  end

  @doc "Cleans up expired cache entries.\nShould be called periodically.\n"
  def cleanup_expired_cache do
    query = from(c in PgpKeyCache, where: c.expires_at < ^DateTime.utc_now())
    Repo.delete_all(query)
  end
end
