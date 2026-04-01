defmodule Elektrine.Email.MailboxEncryption do
  @moduledoc """
  Public-key encryption for optional browser-unlocked mailbox storage.

  The browser generates the mailbox keypair. The server only stores the public
  key, a passphrase-wrapped private key blob, and encrypted message payloads.
  """

  alias Elektrine.Email.AttachmentStorage
  alias Elektrine.Email.Mailbox

  @message_aad "ElektrineMailboxStorageV1"
  @attachment_aad "ElektrineMailboxAttachmentV1"
  @placeholder_subject "Encrypted message"
  @placeholder_attachment_filename "Encrypted attachment"
  @placeholder_attachment_content_type "application/octet-stream"

  @doc """
  Returns true when the mailbox is configured to store private message payloads.
  """
  def enabled?(%Mailbox{private_storage_enabled: true} = mailbox) do
    Mailbox.private_storage_configured?(mailbox)
  end

  def enabled?(_mailbox), do: false

  @doc """
  Returns the generic subject shown server-side when the real subject is protected.
  """
  def placeholder_subject, do: @placeholder_subject

  @doc """
  Returns true when an attachment entry is protected by mailbox encryption.
  """
  def attachment_encrypted?(attachment) when is_map(attachment) do
    attachment
    |> attachment_payload()
    |> valid_payload?()
  end

  def attachment_encrypted?(_attachment), do: false

  @doc """
  Returns the stored encrypted attachment payload envelope, if present.
  """
  def attachment_payload(attachment) when is_map(attachment) do
    Map.get(attachment, "private_encrypted_payload") ||
      Map.get(attachment, :private_encrypted_payload)
  end

  def attachment_payload(_attachment), do: nil

  @doc """
  Encrypts subject and body content for a mailbox using its configured public key.
  """
  def encrypt_message(attrs, %Mailbox{} = mailbox) do
    if enabled?(mailbox) do
      encrypt_payload(attrs, mailbox.private_storage_public_key)
    else
      {:ok, attrs}
    end
  end

  @doc """
  Returns true when a stored message payload matches the mailbox-encryption envelope shape.
  """
  def valid_payload?(payload) when is_map(payload) do
    version = payload_value(payload, "version", :version)
    content_algorithm = payload_value(payload, "content_algorithm", :content_algorithm)
    key_algorithm = payload_value(payload, "key_algorithm", :key_algorithm)
    encrypted_key = payload_value(payload, "encrypted_key", :encrypted_key)
    iv = payload_value(payload, "iv", :iv)
    tag = payload_value(payload, "tag", :tag)
    ciphertext = payload_value(payload, "ciphertext", :ciphertext)

    valid_version?(version) and content_algorithm == "AES-256-GCM" and
      key_algorithm == "RSA-OAEP-SHA256" and valid_base64_bytes?(encrypted_key, min_size: 32) and
      valid_base64_bytes?(iv, exact_size: 12) and valid_base64_bytes?(tag, exact_size: 16) and
      valid_base64_bytes?(ciphertext, min_size: 1)
  end

  def valid_payload?(_payload), do: false

  defp encrypt_payload(attrs, public_key_pem) do
    subject = get_attr(attrs, "subject", :subject)
    text_body = get_attr(attrs, "text_body", :text_body)
    html_body = get_attr(attrs, "html_body", :html_body)
    attachments = get_attr(attrs, "attachments", :attachments) || %{}

    with {:ok, public_key} <- decode_public_key(public_key_pem),
         {:ok, envelope} <-
           maybe_encrypt_message_fields(subject, text_body, html_body, attachments, public_key),
         {:ok, encrypted_attachments} <- encrypt_attachments(attachments, public_key) do
      {:ok,
       attrs
       |> put_attr(:subject, @placeholder_subject)
       |> put_attr(:text_body, nil)
       |> put_attr(:html_body, nil)
       |> put_attr(:search_index, [])
       |> put_attr(:encrypted_text_body, nil)
       |> put_attr(:encrypted_html_body, nil)
       |> put_attr(:attachments, encrypted_attachments)
       |> put_attr(:has_attachments, map_size(encrypted_attachments) > 0)
       |> put_attr(:client_encrypted_payload, envelope)}
    end
  rescue
    _ -> {:error, :private_storage_encryption_failed}
  end

  defp sensitive_content_blank?(subject, text_body, html_body) do
    blank?(subject) and blank?(text_body) and blank?(html_body)
  end

  defp maybe_encrypt_message_fields(subject, text_body, html_body, attachments, public_key) do
    if sensitive_content_blank?(subject, text_body, html_body) and attachments in [nil, %{}] do
      {:ok, nil}
    else
      encrypt_json(
        %{
          "subject" => subject,
          "text_body" => text_body,
          "html_body" => html_body
        },
        public_key,
        @message_aad
      )
    end
  end

  defp encrypt_attachments(attachments, _public_key) when attachments in [nil, %{}],
    do: {:ok, %{}}

  defp encrypt_attachments(attachments, public_key) when is_map(attachments) do
    Enum.reduce_while(attachments, {:ok, %{}}, fn {attachment_id, attachment}, {:ok, acc} ->
      case encrypt_attachment(attachment, public_key) do
        {:ok, encrypted_attachment} ->
          {:cont, {:ok, Map.put(acc, attachment_id, encrypted_attachment)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp encrypt_attachments(_attachments, _public_key),
    do: {:error, :private_storage_attachment_encryption_failed}

  defp encrypt_attachment(attachment, _public_key) when not is_map(attachment) do
    {:error, :private_storage_attachment_encryption_failed}
  end

  defp encrypt_attachment(attachment, public_key) do
    if attachment_encrypted?(attachment) do
      {:ok, attachment}
    else
      with {:ok, content} <- AttachmentStorage.download_attachment(attachment),
           {:ok, envelope} <-
             encrypt_json(
               attachment_payload_map(attachment, content),
               public_key,
               @attachment_aad
             ) do
        {:ok,
         %{
           "filename" => @placeholder_attachment_filename,
           "content_type" => @placeholder_attachment_content_type,
           "size" => Map.get(attachment, "size") || byte_size(content),
           "private_encrypted" => true,
           "private_encrypted_payload" => envelope
         }}
      else
        {:error, _reason} -> {:error, :private_storage_attachment_encryption_failed}
      end
    end
  end

  defp attachment_payload_map(attachment, content) do
    %{
      "filename" => Map.get(attachment, "filename") || @placeholder_attachment_filename,
      "content_type" =>
        Map.get(attachment, "content_type") || @placeholder_attachment_content_type,
      "size" => Map.get(attachment, "size") || byte_size(content),
      "disposition" => Map.get(attachment, "disposition"),
      "content_id" => Map.get(attachment, "content_id"),
      "data" => Base.encode64(content),
      "encoding" => "base64"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp encrypt_json(map, public_key, aad) when is_map(map) do
    payload = Jason.encode!(map)
    content_key = :crypto.strong_rand_bytes(32)
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, content_key, iv, payload, aad, true)

    encrypted_key =
      :public_key.encrypt_public(
        content_key,
        public_key,
        rsa_padding: :rsa_pkcs1_oaep_padding,
        rsa_oaep_md: :sha256,
        rsa_mgf1_md: :sha256
      )

    {:ok,
     %{
       version: 1,
       content_algorithm: "AES-256-GCM",
       key_algorithm: "RSA-OAEP-SHA256",
       encrypted_key: Base.encode64(encrypted_key),
       iv: Base.encode64(iv),
       tag: Base.encode64(tag),
       ciphertext: Base.encode64(ciphertext)
     }}
  end

  defp blank?(value) when is_binary(value), do: not Elektrine.Strings.present?(value)
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp decode_public_key(public_key_pem) when is_binary(public_key_pem) do
    case :public_key.pem_decode(public_key_pem) do
      [entry | _] ->
        {:ok, :public_key.pem_entry_decode(entry)}

      _ ->
        {:error, :invalid_public_key}
    end
  rescue
    _ -> {:error, :invalid_public_key}
  end

  defp decode_public_key(_public_key_pem), do: {:error, :invalid_public_key}

  defp get_attr(attrs, string_key, atom_key) do
    Map.get(attrs, atom_key) || Map.get(attrs, string_key)
  end

  defp put_attr(attrs, key, value) do
    has_atom_keys = Enum.any?(Map.keys(attrs), &is_atom/1)

    if has_atom_keys do
      Map.put(attrs, key, value)
    else
      Map.put(attrs, Atom.to_string(key), value)
    end
  end

  defp payload_value(payload, string_key, atom_key) do
    Map.get(payload, string_key) || Map.get(payload, atom_key)
  end

  defp valid_version?(version) when is_integer(version), do: version >= 1
  defp valid_version?(version) when is_float(version), do: version >= 1
  defp valid_version?(_version), do: false

  defp valid_base64_bytes?(value, opts) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} ->
        size = byte_size(bytes)
        min_size = Keyword.get(opts, :min_size, 0)
        exact_size = Keyword.get(opts, :exact_size)

        size >= min_size and (is_nil(exact_size) or size == exact_size)

      :error ->
        false
    end
  end

  defp valid_base64_bytes?(_value, _opts), do: false
end
