defmodule Elektrine.Email.Receiver do
  @moduledoc """
  Handles incoming email processing functionality.
  """

  alias Elektrine.Email
  alias Elektrine.Email.Mailbox
  alias Elektrine.Email.ForwardedMessage
  alias Elektrine.Repo
  alias Elektrine.Telemetry.Events

  require Logger
  require Sentry

  @doc """
  Processes an incoming email from a webhook.

  This function is designed to be called by a webhook controller
  that receives POST requests from the email server when a new
  email is received.

  ## Parameters

    * `params` - The webhook payload from the email server

  ## Returns

    * `{:ok, message}` - If the email was processed successfully
    * `{:error, reason}` - If there was an error
  """
  def process_incoming_email(params) do
    started_at = System.monotonic_time(:millisecond)

    try do
      # Validate webhook authenticity
      with :ok <- validate_webhook(params),
           {:ok, mailbox} <- find_recipient_mailbox(params),
           :ok <- check_blocked_sender(mailbox.user_id, params),
           {:ok, message} <- store_incoming_message(mailbox.id, params) do
        # Apply user's email filters
        message = apply_user_filters(message, mailbox.user_id)

        # Send notification to any connected LiveViews
        if mailbox do
          Phoenix.PubSub.broadcast!(
            Elektrine.PubSub,
            "user:#{mailbox.user_id}",
            {:new_email, message}
          )

          Phoenix.PubSub.broadcast!(
            Elektrine.PubSub,
            "mailbox:#{mailbox.id}",
            {:new_email, message}
          )

          # Process auto-reply without breaking Ecto Sandbox ownership in tests.
          Elektrine.Async.run(fn -> Email.process_auto_reply(message, mailbox.user_id) end)
        end

        duration = System.monotonic_time(:millisecond) - started_at
        Events.email_inbound(:receiver, :success, duration, %{source: :receiver})
        {:ok, message}
      else
        {:error, :sender_blocked} ->
          Logger.info("Rejected email from blocked sender: #{params["from"]}")
          duration = System.monotonic_time(:millisecond) - started_at

          Events.email_inbound(:receiver, :failure, duration, %{
            reason: :sender_blocked,
            source: :receiver
          })

          {:error, :sender_blocked}

        {:error, reason} = error ->
          # Report non-expected errors to Sentry
          if reason not in [
               :missing_recipient,
               :no_mailbox_found,
               :user_not_found,
               :sender_blocked
             ] do
            Sentry.capture_message("Failed to process incoming email",
              level: :error,
              extra: %{reason: inspect(reason), from: params["from"], to: params["to"]}
            )
          end

          duration = System.monotonic_time(:millisecond) - started_at

          Events.email_inbound(:receiver, :failure, duration, %{reason: reason, source: :receiver})

          error
      end
    rescue
      e ->
        Logger.error("Exception processing incoming email: #{inspect(e)}")
        Logger.error("Stack trace: #{Exception.format_stacktrace()}")
        duration = System.monotonic_time(:millisecond) - started_at

        Events.email_inbound(:receiver, :failure, duration, %{
          reason: :exception,
          source: :receiver
        })

        Sentry.capture_exception(e,
          stacktrace: __STACKTRACE__,
          extra: %{
            context: "email_receiver_processing",
            from: params["from"],
            to: params["to"]
          }
        )

        {:error, :processing_exception}
    end
  end

  # Validates the webhook request authenticity
  defp validate_webhook(params) when is_map(params) do
    email_config = Application.get_env(:elektrine, :email, [])

    webhook_secret =
      System.get_env("EMAIL_RECEIVER_WEBHOOK_SECRET") ||
        Keyword.get(email_config, :receiver_webhook_secret)

    allow_insecure =
      Keyword.get(email_config, :allow_insecure_receiver_webhook, true)

    case webhook_secret do
      secret when is_binary(secret) and secret != "" ->
        provided =
          params["webhook_secret"] || params["signature"] || params["token"] || params["auth"]

        if secure_compare(provided, secret) do
          :ok
        else
          {:error, :invalid_webhook_signature}
        end

      _ when allow_insecure ->
        :ok

      _ ->
        {:error, :webhook_secret_not_configured}
    end
  end

  defp validate_webhook(_params), do: {:error, :invalid_webhook_payload}

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  # Finds the mailbox for the recipient of this email
  defp find_recipient_mailbox(params) do
    find_recipient_mailbox(params, [])
  end

  defp find_recipient_mailbox(params, forwarding_chain) do
    recipient = params["rcpt_to"] || params["to"]

    unless recipient do
      Logger.error("Missing recipient in webhook payload (keys=#{inspect(Map.keys(params))})")
      {:error, :missing_recipient}
    else
      # Check if recipient is an alias first
      case Email.resolve_alias(recipient) do
        # Alias forwards to another email address
        target_email when is_binary(target_email) ->
          # Get alias record for tracking
          alias_record = Email.get_alias_by_email(recipient)

          # Add to forwarding chain
          updated_chain =
            forwarding_chain ++
              [
                %{
                  from: recipient,
                  to: target_email,
                  alias_id: alias_record && alias_record.id
                }
              ]

          # Recursively resolve the target (in case it's also an alias)
          find_recipient_mailbox(Map.put(params, "rcpt_to", target_email), updated_chain)

        # Alias exists but should deliver to alias owner's mailbox (no forwarding)
        :no_forward ->
          find_alias_owner_mailbox(recipient)

        # Not an alias, proceed with normal mailbox lookup
        nil ->
          # Record forwarded message if we went through forwarding
          if forwarding_chain != [] do
            record_forwarded_message(params, forwarding_chain, recipient)
          end

          find_direct_mailbox(recipient)
      end
    end
  end

  # Records a forwarded message to the database for tracking
  defp record_forwarded_message(params, forwarding_chain, final_recipient) do
    first_hop = List.first(forwarding_chain)

    # Convert forwarding chain to the format expected by the schema
    hops =
      Enum.map(forwarding_chain, fn hop ->
        %{
          "from" => hop[:from],
          "to" => hop[:to],
          "alias_id" => hop[:alias_id]
        }
      end)

    # Sanitize all fields to ensure valid UTF-8 for database
    attrs = %{
      message_id: params["message_id"],
      from_address: sanitize_address_header(params["from"] || params["mail_from"]),
      subject: sanitize_header(params["subject"]),
      original_recipient: first_hop[:from],
      final_recipient: final_recipient,
      forwarding_chain: %{hops: hops},
      total_hops: length(forwarding_chain),
      alias_id: first_hop[:alias_id]
    }

    case Repo.insert(ForwardedMessage.changeset(%ForwardedMessage{}, attrs)) do
      {:ok, _record} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to record forwarded message: #{inspect(changeset.errors)}")
    end
  end

  # Sanitize and decode email headers (subjects, from, etc.)
  defp sanitize_header(nil), do: ""
  defp sanitize_header(""), do: ""

  defp sanitize_header(header) when is_binary(header) do
    # Use Mail library to decode RFC 2047 MIME headers, then sanitize UTF-8
    decoded = decode_mail_header(header)
    Elektrine.Email.Sanitizer.sanitize_utf8(decoded)
  end

  # Sanitize and decode email address headers (from, to, cc)
  # These may have format: "Display Name" <email@address.com>
  defp sanitize_address_header(nil), do: ""
  defp sanitize_address_header(""), do: ""

  defp sanitize_address_header(header) when is_binary(header) do
    # Parse email address with display name
    case Regex.run(~r/^(.+?)\s*<([^>]+)>$/, String.trim(header)) do
      [_, display_name, email_address] ->
        # Decode the display name part (may be RFC 2047 encoded)
        decoded_name = decode_mail_header(String.trim(display_name, "\""))
        sanitized_name = Elektrine.Email.Sanitizer.sanitize_utf8(decoded_name)
        sanitized_email = Elektrine.Email.Sanitizer.sanitize_utf8(email_address)

        # Reconstruct: "Display Name" <email@address.com>
        if sanitized_name == sanitized_email or sanitized_name == "" do
          # If display name same as email or empty, just use email
          sanitized_email
        else
          ~s("#{sanitized_name}" <#{sanitized_email}>)
        end

      _ ->
        # No display name, just email address
        decoded = decode_mail_header(header)
        Elektrine.Email.Sanitizer.sanitize_utf8(decoded)
    end
  end

  @doc """
  Decode MIME-encoded headers (RFC 2047).
  Handles: =?charset?encoding?text?= format and encoding issues.

  This function is public so it can be reused by IMAP APPEND handling
  to decode subjects from external email clients like Thunderbird.
  """
  def decode_mail_header(text) when is_binary(text) do
    cond do
      # Check if it contains RFC 2047 encoding markers
      String.contains?(text, "=?") and String.contains?(text, "?=") ->
        decode_rfc2047_manual(text)

      # Check if it looks like UTF-8 bytes interpreted as Latin-1
      # This happens when email servers decode but use wrong charset
      looks_like_mojibake?(text) ->
        fix_mojibake(text)

      # Already valid UTF-8, return as-is
      String.valid?(text) ->
        text

      # Invalid UTF-8, try to fix it
      true ->
        case :unicode.characters_to_binary(text, :latin1, :utf8) do
          result when is_binary(result) -> result
          _ -> text
        end
    end
  end

  # Detect mojibake - UTF-8 bytes incorrectly decoded as Latin-1
  # Common patterns: æ (0xE6), ã (0xE3), ç (0xE7) followed by control chars
  defp looks_like_mojibake?(text) do
    # These patterns indicate UTF-8 bytes interpreted as Latin-1
    # Chinese UTF-8 starts with 0xE4-0xE9 which appear as ä å æ ç è é in Latin-1
    # Japanese/Korean patterns
    # Check for sequences that are valid Latin-1 but likely mojibake
    Regex.match?(~r/[æãçåäè][^\x20-\x7E]/, text) or
      Regex.match?(~r/[ã][€-¿]/, text) or
      (String.valid?(text) and has_suspicious_latin1_sequences?(text))
  end

  # Check for suspicious sequences that indicate mojibake
  defp has_suspicious_latin1_sequences?(text) do
    # Count high-byte characters that are unlikely in real Latin-1 text
    high_byte_count =
      text
      |> String.to_charlist()
      |> Enum.count(fn c -> c >= 0x80 and c <= 0xBF end)

    # If we have many continuation bytes (0x80-0xBF), it's likely mojibake
    high_byte_count > 2 and high_byte_count > String.length(text) / 4
  end

  # Fix mojibake by re-interpreting the Latin-1 bytes as UTF-8
  defp fix_mojibake(text) do
    # Get the raw bytes (Latin-1 interpretation)
    bytes = :binary.bin_to_list(text)

    # Re-interpret those bytes as UTF-8
    case :unicode.characters_to_binary(:erlang.list_to_binary(bytes), :utf8) do
      result when is_binary(result) ->
        if String.valid?(result), do: result, else: text

      _ ->
        # If that doesn't work, return original
        text
    end
  end

  # Manual RFC 2047 decoder
  # Handles MIME encoded-word format: =?charset?encoding?encoded-text?=
  defp decode_rfc2047_manual(text) do
    # RFC 2047 pattern - supports adjacent encoded words
    pattern = ~r/=\?([^?]+)\?([BQ])\?([^?]+)\?=/i

    # First, remove linear whitespace between adjacent encoded words (RFC 2047 section 6.2)
    # Adjacent encoded words should be concatenated without the whitespace
    normalized = Regex.replace(~r/\?=\s+=\?/, text, "?==?")

    Regex.replace(pattern, normalized, fn _, charset, encoding, encoded_text ->
      decode_encoded_word(charset, encoding, encoded_text)
    end)
  end

  # Decode a single RFC 2047 encoded word
  defp decode_encoded_word(charset, encoding, encoded_text) do
    try do
      decoded_bytes =
        case String.upcase(encoding) do
          "B" ->
            # Base64 encoding - handle padding issues
            padded =
              case rem(String.length(encoded_text), 4) do
                0 -> encoded_text
                2 -> encoded_text <> "=="
                3 -> encoded_text <> "="
                _ -> encoded_text
              end

            Base.decode64!(padded)

          "Q" ->
            # Quoted-printable encoding
            encoded_text
            |> String.replace("_", " ")
            |> decode_quoted_printable()

          _ ->
            encoded_text
        end

      # Convert from the specified charset to UTF-8
      convert_charset_to_utf8(decoded_bytes, String.downcase(charset))
    rescue
      e ->
        Logger.warning("RFC 2047 decode failed for #{charset}/#{encoding}: #{inspect(e)}")
        # Return original encoded form on error
        "=?#{charset}?#{encoding}?#{encoded_text}?="
    end
  end

  # Decode quoted-printable encoding
  defp decode_quoted_printable(text) do
    Regex.replace(~r/=([0-9A-F]{2})/i, text, fn _, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end

  # Convert bytes from various charsets to UTF-8
  defp convert_charset_to_utf8(bytes, charset) do
    result =
      case charset do
        # UTF-8 variants
        c when c in ["utf-8", "utf8"] ->
          bytes

        # ASCII variants
        c when c in ["us-ascii", "ascii"] ->
          bytes

        # Latin/Western European
        c when c in ["iso-8859-1", "latin1", "latin-1"] ->
          :unicode.characters_to_binary(bytes, :latin1, :utf8)

        # Windows-1252 (common in Windows emails, superset of Latin-1)
        c when c in ["windows-1252", "cp1252"] ->
          convert_windows1252_to_utf8(bytes)

        # ISO-8859-15 (Latin-9, like Latin-1 but with Euro sign)
        "iso-8859-15" ->
          :unicode.characters_to_binary(bytes, :latin1, :utf8)

        # For CJK charsets (GB2312, GBK, Shift_JIS, EUC-JP, EUC-KR, Big5)
        # Erlang doesn't support these natively, so we try to interpret as UTF-8
        # or return the bytes as-is if they're already valid UTF-8
        c
        when c in [
               "gb2312",
               "gbk",
               "gb18030",
               "shift_jis",
               "shift-jis",
               "euc-jp",
               "iso-2022-jp",
               "euc-kr",
               "iso-2022-kr",
               "big5"
             ] ->
          # If bytes happen to be valid UTF-8, use them
          if String.valid?(bytes) do
            bytes
          else
            # Can't convert without iconv, return with warning
            Logger.warning("Unsupported charset #{charset}, cannot convert to UTF-8")
            # Try Latin-1 as last resort
            case :unicode.characters_to_binary(bytes, :latin1, :utf8) do
              r when is_binary(r) -> r
              _ -> bytes
            end
          end

        # Unknown charset - assume UTF-8 or Latin-1
        _ ->
          if String.valid?(bytes) do
            bytes
          else
            case :unicode.characters_to_binary(bytes, :latin1, :utf8) do
              r when is_binary(r) -> r
              _ -> bytes
            end
          end
      end

    # Ensure result is binary
    case result do
      r when is_binary(r) -> r
      {:error, _, _} -> bytes
      {:incomplete, partial, _} when is_binary(partial) -> partial
      _ -> bytes
    end
  end

  # Convert Windows-1252 to UTF-8
  # Windows-1252 special characters in 0x80-0x9F range (differ from Latin-1)
  @windows1252_map %{
    # € Euro sign
    0x80 => <<0xE2, 0x82, 0xAC>>,
    # ‚ Single low-9 quote
    0x82 => <<0xE2, 0x80, 0x9A>>,
    # ƒ Latin small f with hook
    0x83 => <<0xC6, 0x92>>,
    # „ Double low-9 quote
    0x84 => <<0xE2, 0x80, 0x9E>>,
    # … Horizontal ellipsis
    0x85 => <<0xE2, 0x80, 0xA6>>,
    # † Dagger
    0x86 => <<0xE2, 0x80, 0xA0>>,
    # ‡ Double dagger
    0x87 => <<0xE2, 0x80, 0xA1>>,
    # ˆ Modifier circumflex
    0x88 => <<0xCB, 0x86>>,
    # ‰ Per mille sign
    0x89 => <<0xE2, 0x80, 0xB0>>,
    # Š Latin capital S with caron
    0x8A => <<0xC5, 0xA0>>,
    # ‹ Single left-pointing angle quote
    0x8B => <<0xE2, 0x80, 0xB9>>,
    # Œ Latin capital OE
    0x8C => <<0xC5, 0x92>>,
    # Ž Latin capital Z with caron
    0x8E => <<0xC5, 0xBD>>,
    # ' Left single quote
    0x91 => <<0xE2, 0x80, 0x98>>,
    # ' Right single quote
    0x92 => <<0xE2, 0x80, 0x99>>,
    # " Left double quote
    0x93 => <<0xE2, 0x80, 0x9C>>,
    # " Right double quote
    0x94 => <<0xE2, 0x80, 0x9D>>,
    # • Bullet
    0x95 => <<0xE2, 0x80, 0xA2>>,
    # – En dash
    0x96 => <<0xE2, 0x80, 0x93>>,
    # — Em dash
    0x97 => <<0xE2, 0x80, 0x94>>,
    # ˜ Small tilde
    0x98 => <<0xCB, 0x9C>>,
    # ™ Trade mark
    0x99 => <<0xE2, 0x84, 0xA2>>,
    # š Latin small s with caron
    0x9A => <<0xC5, 0xA1>>,
    # › Single right-pointing angle quote
    0x9B => <<0xE2, 0x80, 0xBA>>,
    # œ Latin small oe
    0x9C => <<0xC5, 0x93>>,
    # ž Latin small z with caron
    0x9E => <<0xC5, 0xBE>>,
    # Ÿ Latin capital Y with diaeresis
    0x9F => <<0xC5, 0xB8>>
  }

  defp convert_windows1252_to_utf8(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn byte ->
      case Map.get(@windows1252_map, byte) do
        nil when byte < 0x80 -> <<byte>>
        nil -> :unicode.characters_to_binary(<<byte>>, :latin1, :utf8)
        char -> char
      end
    end)
    |> Enum.map_join("", & &1)
  end

  # Find the mailbox for an alias that doesn't forward (delivers to alias owner)
  defp find_alias_owner_mailbox(alias_email) do
    case Email.get_alias_by_email(alias_email) do
      %Email.Alias{user_id: user_id} when is_integer(user_id) ->
        case Email.get_user_mailbox(user_id) do
          %Mailbox{} = mailbox ->
            {:ok, mailbox}

          nil ->
            Logger.warning("Alias #{alias_email} owner has no mailbox")
            {:error, :no_mailbox_found}
        end

      _ ->
        Logger.warning("Could not find alias #{alias_email}")
        {:error, :no_mailbox_found}
    end
  end

  # Find direct mailbox (original logic)
  defp find_direct_mailbox(recipient) do
    import Ecto.Query

    # First try exact email match
    mailbox =
      Mailbox
      |> where(email: ^recipient)
      |> Repo.one()

    case mailbox do
      nil ->
        # If no exact match, try to find by username across supported domains
        case find_mailbox_by_cross_domain_lookup(recipient) do
          nil ->
            # Try to create mailbox if it's for a supported domain
            case auto_create_mailbox_if_valid(recipient) do
              {:ok, new_mailbox} ->
                {:ok, new_mailbox}

              {:error, reason} ->
                Logger.warning("No mailbox found for recipient: #{recipient}, reason: #{reason}")
                {:error, :no_mailbox_found}
            end

          found_mailbox ->
            {:ok, found_mailbox}
        end

      mailbox ->
        # Check if existing mailbox has proper user association
        if is_nil(mailbox.user_id) do
          case fix_orphaned_mailbox(mailbox) do
            {:ok, fixed_mailbox} ->
              {:ok, fixed_mailbox}

            {:error, reason} ->
              Logger.error("Failed to fix orphaned mailbox #{mailbox.email}: #{reason}")
              # Use it anyway to avoid breaking email flow
              {:ok, mailbox}
          end
        else
          {:ok, mailbox}
        end
    end
  end

  # Attempts to find a mailbox by looking up the username across all supported domains
  defp find_mailbox_by_cross_domain_lookup(email) do
    case extract_username_and_domain(email) do
      {username, domain} ->
        supported_domains =
          Application.get_env(:elektrine, :email)[:supported_domains] ||
            ["elektrine.com", "z.org"]

        if domain in supported_domains do
          # Try to find a mailbox for this username with any of the supported domains
          import Ecto.Query

          like_patterns = Enum.map(supported_domains, fn d -> "#{username}@#{d}" end)

          Mailbox
          |> where([m], m.email in ^like_patterns)
          |> Repo.one()
        else
          nil
        end

      _ ->
        nil
    end
  end

  # Extracts username and domain from an email address
  defp extract_username_and_domain(email) do
    case String.split(email, "@") do
      [username, domain] -> {username, domain}
      _ -> nil
    end
  end

  # Stores the incoming message in the database
  defp store_incoming_message(mailbox_id, params) do
    # Sanitize ALL header fields using Mail library for MIME decoding + UTF-8 sanitization
    sender_email = sanitize_address_header(params["from"] || params["mail_from"])

    # Process attachments first (without data)
    attachments_metadata = prepare_attachments_metadata(params["attachments"])

    # Base message attributes - sanitize all header fields
    message_attrs = %{
      "message_id" => params["message_id"] || "incoming-#{:rand.uniform(1_000_000)}",
      "from" => sender_email,
      "to" => sanitize_address_header(params["to"] || params["rcpt_to"]),
      "cc" => sanitize_address_header(params["cc"]),
      "bcc" => sanitize_address_header(params["bcc"]),
      "subject" => sanitize_header(params["subject"]),
      "text_body" =>
        Elektrine.Email.Sanitizer.sanitize_utf8(params["plain_body"] || params["text_body"] || ""),
      "html_body" => Elektrine.Email.Sanitizer.sanitize_utf8(params["html_body"] || ""),
      "status" => "received",
      "read" => false,
      "spam" => is_spam?(params),
      "archived" => false,
      "mailbox_id" => mailbox_id,
      "metadata" => extract_metadata(params),
      "attachments" => attachments_metadata,
      "has_attachments" => map_size(attachments_metadata) > 0
    }

    # Apply automatic categorization if not spam
    message_attrs =
      if not message_attrs["spam"] do
        Email.categorize_message(message_attrs)
      else
        message_attrs
      end

    # Allowlist of valid email message fields to prevent atom exhaustion DoS
    valid_message_keys = ~w(
      message_id from to cc bcc subject text_body html_body encrypted_text_body
      encrypted_html_body search_index status read spam archived deleted flagged
      answered metadata category stack_at stack_reason reply_later_at
      reply_later_reminder is_receipt is_notification is_newsletter opened_at
      first_opened_at open_count attachments has_attachments hash in_reply_to
      references jmap_blob_id priority scheduled_at expires_at undo_send_until
      mailbox_id thread_id label_ids folder_id
    )

    # Convert string keys to atoms for changeset - only allow known fields
    message_attrs =
      for {key, val} <- message_attrs, key in valid_message_keys, into: %{} do
        {String.to_existing_atom(key), val}
      end

    # Create the message first
    case Email.create_message(message_attrs) do
      {:ok, message} ->
        # Upload attachments to S3/R2 asynchronously to avoid blocking SMTP
        if params["attachments"] && params["attachments"] != [] do
          # Spawn async task to upload to S3 - don't wait for it
          Elektrine.Async.run(fn ->
            Elektrine.Jobs.AttachmentUploader.upload_message_attachments(message.id)
          end)
        end

        {:ok, message}

      error ->
        error
    end
  end

  # Prepares attachment metadata without the actual data
  defp prepare_attachments_metadata(nil), do: %{}
  defp prepare_attachments_metadata([]), do: %{}

  defp prepare_attachments_metadata(attachments) when is_list(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {attachment, index}, acc ->
      attachment_id = "attachment_#{index}"

      # Decode filename (may be RFC 2047 encoded)
      raw_filename = attachment["name"] || attachment["filename"] || "attachment_#{index}"
      decoded_filename = decode_attachment_filename(raw_filename)

      metadata =
        %{
          "filename" => decoded_filename,
          "content_type" =>
            attachment["content_type"] || attachment["mime_type"] || "application/octet-stream",
          "size" =>
            attachment["size"] || (attachment["data"] && byte_size(attachment["data"])) || 0,
          "content_id" => attachment["content_id"],
          "disposition" => attachment["disposition"] || "attachment"
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Enum.into(%{})

      Map.put(acc, attachment_id, metadata)
    end)
  end

  defp prepare_attachments_metadata(_), do: %{}

  # Decode attachment filename (may be RFC 2047 encoded)
  defp decode_attachment_filename(nil), do: "attachment"
  defp decode_attachment_filename(""), do: "attachment"

  defp decode_attachment_filename(filename) when is_binary(filename) do
    decoded = decode_mail_header(filename)
    Elektrine.Email.Sanitizer.sanitize_utf8(decoded)
  end

  # Extracts useful metadata from the webhook payload
  # CRITICAL: Sanitize all string fields to prevent invalid UTF-8 in JSONB
  defp extract_metadata(params) do
    %{
      received_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      spam_score: params["spam_score"],
      attachments: params["attachments"],
      headers: sanitize_headers_map(params["headers"])
    }
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Enum.into(%{})
  end

  # Sanitize a map of headers (recursively sanitize all string values)
  defp sanitize_headers_map(nil), do: nil

  defp sanitize_headers_map(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {k, v} ->
      {k, sanitize_metadata_value(v)}
    end)
    |> Map.new()
  end

  defp sanitize_headers_map(_), do: nil

  # Sanitize any metadata value (handles strings, lists, maps, etc.)
  defp sanitize_metadata_value(value) when is_binary(value) do
    Elektrine.Email.Sanitizer.sanitize_utf8(value)
  end

  defp sanitize_metadata_value(value) when is_list(value) do
    Enum.map(value, &sanitize_metadata_value/1)
  end

  defp sanitize_metadata_value(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {k, sanitize_metadata_value(v)} end)
    |> Map.new()
  end

  defp sanitize_metadata_value(value), do: value

  # Determines if the message is spam based on email server's spam headers
  defp is_spam?(params) do
    # Check legacy spam field for backwards compatibility
    case params["spam"] do
      true -> true
      "true" -> true
      1 -> true
      "1" -> true
      _ -> false
    end
  end

  # Auto-create mailbox for valid email addresses
  defp auto_create_mailbox_if_valid(email) do
    case extract_username_and_domain(email) do
      {username, domain} ->
        supported_domains =
          Application.get_env(:elektrine, :email)[:supported_domains] ||
            ["elektrine.com", "z.org"]

        if domain in supported_domains do
          # Try multiple user lookup strategies
          user = find_user_for_email(username, email)

          case user do
            nil ->
              {:error, :user_not_found}

            user ->
              # Create mailbox for this user with specific email
              case Email.create_mailbox(%{"email" => email, "user_id" => user.id}) do
                {:ok, mailbox} ->
                  {:ok, mailbox}

                {:error, changeset} ->
                  Logger.error("Failed to create mailbox #{email}: #{inspect(changeset.errors)}")
                  {:error, :mailbox_creation_failed}
              end
          end
        else
          {:error, :unsupported_domain}
        end

      nil ->
        {:error, :invalid_email_format}
    end
  end

  # Find user using multiple lookup strategies
  defp find_user_for_email(username, _full_email) do
    import Ecto.Query

    # Strategy 1: Exact username match
    case Elektrine.Accounts.get_user_by_username(username) do
      nil ->
        # Strategy 2: Look for user by email (in case they have different username)
        # This helps when someone's username is different from their email prefix
        from(u in Elektrine.Accounts.User,
          where: fragment("LOWER(?)", u.username) == ^String.downcase(username),
          limit: 1
        )
        |> Elektrine.Repo.one()

      user ->
        user
    end
  end

  # Fix a single orphaned mailbox by associating it with the correct user
  defp fix_orphaned_mailbox(mailbox) do
    case String.split(mailbox.email, "@") do
      [username, domain] ->
        supported_domains =
          Application.get_env(:elektrine, :email)[:supported_domains] ||
            ["elektrine.com", "z.org"]

        if domain in supported_domains do
          case Elektrine.Accounts.get_user_by_username(username) do
            nil ->
              {:error, :user_not_found}

            user ->
              changeset = Elektrine.Email.Mailbox.changeset(mailbox, %{user_id: user.id})

              case Elektrine.Repo.update(changeset) do
                {:ok, updated_mailbox} ->
                  {:ok, updated_mailbox}

                {:error, changeset} ->
                  {:error, changeset.errors}
              end
          end
        else
          {:error, :unsupported_domain}
        end

      _ ->
        {:error, :invalid_email_format}
    end
  end

  # Checks if the sender is blocked by the user
  defp check_blocked_sender(user_id, params) do
    from_email = params["from"]

    if Email.is_blocked?(user_id, from_email) do
      {:error, :sender_blocked}
    else
      :ok
    end
  end

  # Applies user's email filters to the message
  defp apply_user_filters(message, user_id) do
    actions = Email.apply_filters(user_id, message)

    case Email.execute_actions(message, actions) do
      {:ok, updated_message} ->
        updated_message

      {:error, _reason} ->
        # If filter execution fails, return original message
        message
    end
  end
end
