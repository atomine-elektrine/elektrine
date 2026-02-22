defmodule Elektrine.Email.Receiver do
  @moduledoc "Handles incoming email processing functionality.\n"
  alias Elektrine.Email
  alias Elektrine.Email.ForwardedMessage
  alias Elektrine.Email.Mailbox
  alias Elektrine.Repo
  alias Elektrine.Telemetry.Events
  require Logger
  require Sentry

  @doc "Processes an incoming email from a webhook.\n\nThis function is designed to be called by a webhook controller\nthat receives POST requests from the email server when a new\nemail is received.\n\n## Parameters\n\n  * `params` - The webhook payload from the email server\n\n## Returns\n\n  * `{:ok, message}` - If the email was processed successfully\n  * `{:error, reason}` - If there was an error\n"
  def process_incoming_email(params) do
    started_at = System.monotonic_time(:millisecond)

    try do
      with :ok <- validate_webhook(params),
           {:ok, mailbox} <- find_recipient_mailbox(params),
           :ok <- check_blocked_sender(mailbox.user_id, params),
           {:ok, message} <- store_incoming_message(mailbox.id, params) do
        message = apply_user_filters(message, mailbox.user_id)

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
          extra: %{context: "email_receiver_processing", from: params["from"], to: params["to"]}
        )

        {:error, :processing_exception}
    end
  end

  defp validate_webhook(params) when is_map(params) do
    email_config = Application.get_env(:elektrine, :email, [])

    webhook_secret =
      System.get_env("EMAIL_RECEIVER_WEBHOOK_SECRET") ||
        Keyword.get(email_config, :receiver_webhook_secret)

    allow_insecure = Keyword.get(email_config, :allow_insecure_receiver_webhook, true)

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

  defp validate_webhook(_params) do
    {:error, :invalid_webhook_payload}
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right) do
    false
  end

  defp find_recipient_mailbox(params) do
    find_recipient_mailbox(params, [])
  end

  defp find_recipient_mailbox(params, forwarding_chain) do
    recipient = params["rcpt_to"] || params["to"]

    if recipient do
      case Email.resolve_alias(recipient) do
        target_email when is_binary(target_email) ->
          alias_record = Email.get_alias_by_email(recipient)

          updated_chain =
            forwarding_chain ++
              [%{from: recipient, to: target_email, alias_id: alias_record && alias_record.id}]

          find_recipient_mailbox(Map.put(params, "rcpt_to", target_email), updated_chain)

        :no_forward ->
          find_alias_owner_mailbox(recipient)

        nil ->
          if forwarding_chain != [] do
            record_forwarded_message(params, forwarding_chain, recipient)
          end

          find_direct_mailbox(recipient)
      end
    else
      Logger.error("Missing recipient in webhook payload (keys=#{inspect(Map.keys(params))})")
      {:error, :missing_recipient}
    end
  end

  defp record_forwarded_message(params, forwarding_chain, final_recipient) do
    first_hop = List.first(forwarding_chain)

    hops =
      Enum.map(forwarding_chain, fn hop ->
        %{"from" => hop[:from], "to" => hop[:to], "alias_id" => hop[:alias_id]}
      end)

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

  defp sanitize_header(nil) do
    ""
  end

  defp sanitize_header("") do
    ""
  end

  defp sanitize_header(header) when is_binary(header) do
    decoded = decode_mail_header(header)
    Elektrine.Email.Sanitizer.sanitize_utf8(decoded)
  end

  defp sanitize_address_header(nil) do
    ""
  end

  defp sanitize_address_header("") do
    ""
  end

  defp sanitize_address_header(header) when is_binary(header) do
    case Regex.run(~r/^(.+?)\s*<([^>]+)>$/, String.trim(header)) do
      [_, display_name, email_address] ->
        decoded_name = decode_mail_header(String.trim(display_name, "\""))
        sanitized_name = Elektrine.Email.Sanitizer.sanitize_utf8(decoded_name)
        sanitized_email = Elektrine.Email.Sanitizer.sanitize_utf8(email_address)

        if sanitized_name == sanitized_email or sanitized_name == "" do
          sanitized_email
        else
          ~s("#{sanitized_name}" <#{sanitized_email}>)
        end

      _ ->
        decoded = decode_mail_header(header)
        Elektrine.Email.Sanitizer.sanitize_utf8(decoded)
    end
  end

  @doc "Decode MIME-encoded headers (RFC 2047).\nHandles: =?charset?encoding?text?= format and encoding issues.\n\nThis function is public so it can be reused by IMAP APPEND handling\nto decode subjects from external email clients like Thunderbird.\n"
  def decode_mail_header(text) when is_binary(text) do
    cond do
      String.contains?(text, "=?") and String.contains?(text, "?=") ->
        decode_rfc2047_manual(text)

      looks_like_mojibake?(text) ->
        fix_mojibake(text)

      String.valid?(text) ->
        text

      true ->
        case :unicode.characters_to_binary(text, :latin1, :utf8) do
          result when is_binary(result) -> result
          _ -> text
        end
    end
  end

  defp looks_like_mojibake?(text) do
    Regex.match?(~r/[æãçåäè][^\x20-\x7E]/, text) or Regex.match?(~r/[ã][€-¿]/, text) or
      (String.valid?(text) and has_suspicious_latin1_sequences?(text))
  end

  defp has_suspicious_latin1_sequences?(text) do
    high_byte_count =
      text |> String.to_charlist() |> Enum.count(fn c -> c >= 128 and c <= 191 end)

    high_byte_count > 2 and high_byte_count > String.length(text) / 4
  end

  defp fix_mojibake(text) do
    bytes = :binary.bin_to_list(text)

    case :unicode.characters_to_binary(:erlang.list_to_binary(bytes), :utf8) do
      result when is_binary(result) ->
        if String.valid?(result) do
          result
        else
          text
        end

      _ ->
        text
    end
  end

  defp decode_rfc2047_manual(text) do
    pattern = ~r/=\?([^?]+)\?([BQ])\?([^?]+)\?=/i
    normalized = Regex.replace(~r/\?=\s+=\?/, text, "?==?")

    Regex.replace(pattern, normalized, fn _, charset, encoding, encoded_text ->
      decode_encoded_word(charset, encoding, encoded_text)
    end)
  end

  defp decode_encoded_word(charset, encoding, encoded_text) do
    decoded_bytes =
      case String.upcase(encoding) do
        "B" ->
          padded =
            case rem(String.length(encoded_text), 4) do
              0 -> encoded_text
              2 -> encoded_text <> "=="
              3 -> encoded_text <> "="
              _ -> encoded_text
            end

          Base.decode64!(padded)

        "Q" ->
          encoded_text |> String.replace("_", " ") |> decode_quoted_printable()

        _ ->
          encoded_text
      end

    convert_charset_to_utf8(decoded_bytes, String.downcase(charset))
  rescue
    e ->
      Logger.warning("RFC 2047 decode failed for #{charset}/#{encoding}: #{inspect(e)}")
      "=?#{charset}?#{encoding}?#{encoded_text}?="
  end

  defp decode_quoted_printable(text) do
    Regex.replace(~r/=([0-9A-F]{2})/i, text, fn _, hex -> <<String.to_integer(hex, 16)>> end)
  end

  defp convert_charset_to_utf8(bytes, charset) do
    result =
      case charset do
        c when c in ["utf-8", "utf8"] ->
          bytes

        c when c in ["us-ascii", "ascii"] ->
          bytes

        c when c in ["iso-8859-1", "latin1", "latin-1"] ->
          :unicode.characters_to_binary(bytes, :latin1, :utf8)

        c when c in ["windows-1252", "cp1252"] ->
          convert_windows1252_to_utf8(bytes)

        "iso-8859-15" ->
          :unicode.characters_to_binary(bytes, :latin1, :utf8)

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
          if String.valid?(bytes) do
            bytes
          else
            Logger.warning("Unsupported charset #{charset}, cannot convert to UTF-8")

            case :unicode.characters_to_binary(bytes, :latin1, :utf8) do
              r when is_binary(r) -> r
              _ -> bytes
            end
          end

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

    case result do
      r when is_binary(r) -> r
      {:error, _, _} -> bytes
      {:incomplete, partial, _} when is_binary(partial) -> partial
      _ -> bytes
    end
  end

  @windows1252_map %{
    128 => <<226, 130, 172>>,
    130 => <<226, 128, 154>>,
    131 => <<198, 146>>,
    132 => <<226, 128, 158>>,
    133 => <<226, 128, 166>>,
    134 => <<226, 128, 160>>,
    135 => <<226, 128, 161>>,
    136 => <<203, 134>>,
    137 => <<226, 128, 176>>,
    138 => <<197, 160>>,
    139 => <<226, 128, 185>>,
    140 => <<197, 146>>,
    142 => <<197, 189>>,
    145 => <<226, 128, 152>>,
    146 => <<226, 128, 153>>,
    147 => <<226, 128, 156>>,
    148 => <<226, 128, 157>>,
    149 => <<226, 128, 162>>,
    150 => <<226, 128, 147>>,
    151 => <<226, 128, 148>>,
    152 => <<203, 156>>,
    153 => <<226, 132, 162>>,
    154 => <<197, 161>>,
    155 => <<226, 128, 186>>,
    156 => <<197, 147>>,
    158 => <<197, 190>>,
    159 => <<197, 184>>
  }
  defp convert_windows1252_to_utf8(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn byte ->
      case Map.get(@windows1252_map, byte) do
        nil when byte < 128 -> <<byte>>
        nil -> :unicode.characters_to_binary(<<byte>>, :latin1, :utf8)
        char -> char
      end
    end)
    |> Enum.map_join("", & &1)
  end

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

  defp find_direct_mailbox(recipient) do
    import Ecto.Query
    mailbox = Mailbox |> where(email: ^recipient) |> Repo.one()

    case mailbox do
      nil ->
        case find_mailbox_by_cross_domain_lookup(recipient) do
          nil ->
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
        if is_nil(mailbox.user_id) do
          case fix_orphaned_mailbox(mailbox) do
            {:ok, fixed_mailbox} ->
              {:ok, fixed_mailbox}

            {:error, reason} ->
              Logger.error("Failed to fix orphaned mailbox #{mailbox.email}: #{reason}")
              {:ok, mailbox}
          end
        else
          {:ok, mailbox}
        end
    end
  end

  defp find_mailbox_by_cross_domain_lookup(email) do
    case extract_username_and_domain(email) do
      {username, domain} ->
        supported_domains =
          Application.get_env(:elektrine, :email)[:supported_domains] ||
            ["elektrine.com", "z.org"]

        if domain in supported_domains do
          import Ecto.Query
          like_patterns = Enum.map(supported_domains, fn d -> "#{username}@#{d}" end)
          Mailbox |> where([m], m.email in ^like_patterns) |> Repo.one()
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp extract_username_and_domain(email) do
    case String.split(email, "@") do
      [username, domain] -> {username, domain}
      _ -> nil
    end
  end

  defp store_incoming_message(mailbox_id, params) do
    sender_email = sanitize_address_header(params["from"] || params["mail_from"])
    attachments_metadata = prepare_attachments_metadata(params["attachments"])

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
      "spam" => spam?(params),
      "archived" => false,
      "mailbox_id" => mailbox_id,
      "metadata" => extract_metadata(params),
      "attachments" => attachments_metadata,
      "has_attachments" => map_size(attachments_metadata) > 0
    }

    message_attrs =
      if message_attrs["spam"] do
        message_attrs
      else
        Email.categorize_message(message_attrs)
      end

    valid_message_keys = ~w(
      message_id from to cc bcc subject text_body html_body encrypted_text_body
      encrypted_html_body search_index status read spam archived deleted flagged
      answered metadata category stack_at stack_reason reply_later_at
      reply_later_reminder is_receipt is_notification is_newsletter opened_at
      first_opened_at open_count attachments has_attachments hash in_reply_to
      references jmap_blob_id priority scheduled_at expires_at undo_send_until
      mailbox_id thread_id label_ids folder_id
    )

    message_attrs =
      for {key, val} <- message_attrs, key in valid_message_keys, into: %{} do
        {String.to_existing_atom(key), val}
      end

    case Email.create_message(message_attrs) do
      {:ok, message} ->
        if params["attachments"] && params["attachments"] != [] do
          Elektrine.Async.run(fn ->
            Elektrine.Jobs.AttachmentUploader.upload_message_attachments(message.id)
          end)
        end

        {:ok, message}

      error ->
        error
    end
  end

  defp prepare_attachments_metadata(nil) do
    %{}
  end

  defp prepare_attachments_metadata([]) do
    %{}
  end

  defp prepare_attachments_metadata(attachments) when is_list(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {attachment, index}, acc ->
      attachment_id = "attachment_#{index}"
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

  defp prepare_attachments_metadata(_) do
    %{}
  end

  defp decode_attachment_filename(nil) do
    "attachment"
  end

  defp decode_attachment_filename("") do
    "attachment"
  end

  defp decode_attachment_filename(filename) when is_binary(filename) do
    decoded = decode_mail_header(filename)
    Elektrine.Email.Sanitizer.sanitize_utf8(decoded)
  end

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

  defp sanitize_headers_map(nil) do
    nil
  end

  defp sanitize_headers_map(headers) when is_map(headers) do
    headers |> Enum.map(fn {k, v} -> {k, sanitize_metadata_value(v)} end) |> Map.new()
  end

  defp sanitize_headers_map(_) do
    nil
  end

  defp sanitize_metadata_value(value) when is_binary(value) do
    Elektrine.Email.Sanitizer.sanitize_utf8(value)
  end

  defp sanitize_metadata_value(value) when is_list(value) do
    Enum.map(value, &sanitize_metadata_value/1)
  end

  defp sanitize_metadata_value(value) when is_map(value) do
    value |> Enum.map(fn {k, v} -> {k, sanitize_metadata_value(v)} end) |> Map.new()
  end

  defp sanitize_metadata_value(value) do
    value
  end

  defp spam?(params) do
    case params["spam"] do
      true -> true
      "true" -> true
      1 -> true
      "1" -> true
      _ -> false
    end
  end

  defp auto_create_mailbox_if_valid(email) do
    case extract_username_and_domain(email) do
      {username, domain} ->
        supported_domains =
          Application.get_env(:elektrine, :email)[:supported_domains] ||
            ["elektrine.com", "z.org"]

        if domain in supported_domains do
          user = find_user_for_email(username, email)

          case user do
            nil ->
              {:error, :user_not_found}

            user ->
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

  defp find_user_for_email(username, _full_email) do
    import Ecto.Query

    case Elektrine.Accounts.get_user_by_username(username) do
      nil ->
        from(u in Elektrine.Accounts.User,
          where: fragment("LOWER(?)", u.username) == ^String.downcase(username),
          limit: 1
        )
        |> Elektrine.Repo.one()

      user ->
        user
    end
  end

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
                {:ok, updated_mailbox} -> {:ok, updated_mailbox}
                {:error, changeset} -> {:error, changeset.errors}
              end
          end
        else
          {:error, :unsupported_domain}
        end

      _ ->
        {:error, :invalid_email_format}
    end
  end

  defp check_blocked_sender(user_id, params) do
    from_email = params["from"]

    if Email.blocked?(user_id, from_email) do
      {:error, :sender_blocked}
    else
      :ok
    end
  end

  defp apply_user_filters(message, user_id) do
    actions = Email.apply_filters(user_id, message)

    case Email.execute_actions(message, actions) do
      {:ok, updated_message} -> updated_message
      {:error, _reason} -> message
    end
  end
end
