defmodule Elektrine.Email.MailboxEncryption do
  @moduledoc """
  Public-key encryption for optional browser-unlocked mailbox storage.

  The browser generates the mailbox keypair. The server only stores the public
  key, a passphrase-wrapped private key blob, and encrypted message payloads.
  """

  alias Elektrine.Email.AttachmentStorage
  alias Elektrine.Email.Mailbox

  @placeholder_subject "Encrypted message"
  @placeholder_sender "Encrypted sender"
  @placeholder_recipients "Encrypted recipients"
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
  Returns the generic sender shown server-side when the real sender is protected.
  """
  def placeholder_sender, do: @placeholder_sender

  @doc """
  Returns the generic recipient text shown server-side when real recipients are protected.
  """
  def placeholder_recipients, do: @placeholder_recipients

  @doc """
  Returns true when an attachment entry is protected by mailbox encryption.
  """
  def attachment_encrypted?(attachment) when is_map(attachment) do
    attachment
    |> attachment_payload()
    |> valid_payload?(:attachment)
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
  def valid_payload?(payload, expected_kind \\ nil)

  def valid_payload?(payload, expected_kind) when is_map(payload) do
    version = payload_value(payload, "version", :version)
    content_algorithm = payload_value(payload, "content_algorithm", :content_algorithm)
    key_algorithm = payload_value(payload, "key_algorithm", :key_algorithm)
    encrypted_key = payload_value(payload, "encrypted_key", :encrypted_key)
    iv = payload_value(payload, "iv", :iv)
    tag = payload_value(payload, "tag", :tag)
    ciphertext = payload_value(payload, "ciphertext", :ciphertext)

    valid_version?(version) and valid_aad_context?(payload, version, expected_kind) and
      content_algorithm == "AES-256-GCM" and
      key_algorithm == "RSA-OAEP-SHA256" and valid_base64_bytes?(encrypted_key, min_size: 32) and
      valid_base64_bytes?(iv, exact_size: 12) and valid_base64_bytes?(tag, exact_size: 16) and
      valid_base64_bytes?(ciphertext, min_size: 1)
  end

  def valid_payload?(_payload, _expected_kind), do: false

  defp encrypt_payload(attrs, public_key_pem) do
    from = get_attr(attrs, "from", :from)
    to = get_attr(attrs, "to", :to)
    cc = get_attr(attrs, "cc", :cc)
    bcc = get_attr(attrs, "bcc", :bcc)
    subject = get_attr(attrs, "subject", :subject)
    text_body = get_attr(attrs, "text_body", :text_body)
    html_body = get_attr(attrs, "html_body", :html_body)
    attachments = get_attr(attrs, "attachments", :attachments) || %{}
    metadata = get_attr(attrs, "metadata", :metadata) || %{}

    with {:ok, public_key} <- decode_public_key(public_key_pem),
         {:ok, envelope} <-
           maybe_encrypt_message_fields(
             from,
             to,
             cc,
             bcc,
             subject,
             text_body,
             html_body,
             attachments,
             public_key
           ),
         {:ok, encrypted_attachments} <- encrypt_attachments(attachments, public_key) do
      {:ok,
       attrs
       |> put_attr(:from, placeholder_or_original(from, @placeholder_sender))
       |> put_attr(:to, placeholder_or_original(to, @placeholder_recipients))
       |> put_attr(:cc, placeholder_or_original(cc, @placeholder_recipients))
       |> put_attr(:bcc, placeholder_or_original(bcc, @placeholder_recipients))
       |> put_attr(:subject, @placeholder_subject)
       |> put_attr(:text_body, nil)
       |> put_attr(:html_body, nil)
       |> put_attr(:search_index, [])
       |> put_attr(:encrypted_text_body, nil)
       |> put_attr(:encrypted_html_body, nil)
       |> put_attr(:metadata, private_storage_metadata(metadata))
       |> put_attr(:attachments, encrypted_attachments)
       |> put_attr(:has_attachments, map_size(encrypted_attachments) > 0)
       |> put_attr(:client_encrypted_payload, envelope)}
    end
  rescue
    _ -> {:error, :private_storage_encryption_failed}
  end

  defp sensitive_content_blank?(from, to, cc, bcc, subject, text_body, html_body) do
    Enum.all?([from, to, cc, bcc, subject, text_body, html_body], &blank?/1)
  end

  defp maybe_encrypt_message_fields(
         from,
         to,
         cc,
         bcc,
         subject,
         text_body,
         html_body,
         attachments,
         public_key
       ) do
    if sensitive_content_blank?(from, to, cc, bcc, subject, text_body, html_body) and
         attachments in [nil, %{}] do
      {:ok, nil}
    else
      encrypt_json(
        %{
          "from" => from,
          "to" => to,
          "cc" => cc,
          "bcc" => bcc,
          "subject" => subject,
          "text_body" => text_body,
          "html_body" => html_body
        },
        public_key,
        :message
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
               :attachment
             ) do
        {:ok,
         %{
           "filename" => @placeholder_attachment_filename,
           "content_type" => @placeholder_attachment_content_type,
           "size" => 0,
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

  defp private_storage_metadata(metadata) when is_map(metadata) do
    allowed_keys = ~w(
      body_format
      client_message_id
      delivery_id
      external_delivery
      internal_delivery
      original_message_id
      private_storage
      provider_message_id
      received_at
      sent_at
      spam_score
      trace_id
    )

    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      string_key = to_string(key)

      if string_key in allowed_keys and metadata_value_safe?(value) do
        Map.put(acc, string_key, value)
      else
        acc
      end
    end)
    |> Map.put("private_storage", true)
  end

  defp private_storage_metadata(_metadata), do: %{"private_storage" => true}

  defp metadata_value_safe?(value) when is_binary(value), do: byte_size(value) <= 500
  defp metadata_value_safe?(value) when is_boolean(value), do: true
  defp metadata_value_safe?(value) when is_number(value), do: true
  defp metadata_value_safe?(nil), do: true
  defp metadata_value_safe?(_value), do: false

  defp encrypt_json(map, public_key, kind) when is_map(map) do
    payload = Jason.encode!(map)
    content_key = :crypto.strong_rand_bytes(32)
    iv = :crypto.strong_rand_bytes(12)
    aad_context = aad_context(kind)
    aad = canonical_json(aad_context)

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
       version: 2,
       content_algorithm: "AES-256-GCM",
       key_algorithm: "RSA-OAEP-SHA256",
       aad_context: aad_context,
       encrypted_key: Base.encode64(encrypted_key),
       iv: Base.encode64(iv),
       tag: Base.encode64(tag),
       ciphertext: Base.encode64(ciphertext)
     }}
  end

  defp blank?(value) when is_binary(value), do: not Elektrine.Strings.present?(value)
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp placeholder_or_original(value, _placeholder) when value in [nil, ""], do: value
  defp placeholder_or_original(_value, placeholder), do: placeholder

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

  defp valid_version?(version) when is_integer(version), do: version in [1, 2]
  defp valid_version?(version) when is_float(version), do: version in [1.0, 2.0]
  defp valid_version?(_version), do: false

  defp valid_aad_context?(_payload, version, _expected_kind) when version in [1, 1.0], do: true

  defp valid_aad_context?(payload, version, expected_kind) when version in [2, 2.0] do
    case payload_value(payload, "aad_context", :aad_context) do
      %{} = context ->
        kind = payload_value(context, "kind", :kind)

        payload_value(context, "purpose", :purpose) == "elektrine-private-mailbox" and
          payload_value(context, "version", :version) in [2, 2.0] and
          kind in ["message", "attachment"] and
          (is_nil(expected_kind) or kind == Atom.to_string(expected_kind)) and
          payload_value(context, "content_algorithm", :content_algorithm) == "AES-256-GCM" and
          payload_value(context, "key_algorithm", :key_algorithm) == "RSA-OAEP-SHA256"

      _ ->
        false
    end
  end

  defp valid_aad_context?(_payload, _version, _expected_kind), do: false

  defp aad_context(kind) when kind in [:message, :attachment] do
    %{
      "purpose" => "elektrine-private-mailbox",
      "version" => 2,
      "kind" => Atom.to_string(kind),
      "content_algorithm" => "AES-256-GCM",
      "key_algorithm" => "RSA-OAEP-SHA256"
    }
  end

  defp canonical_json(%{} = map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(",", fn {key, value} ->
      Jason.encode!(to_string(key)) <> ":" <> Jason.encode!(value)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

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
