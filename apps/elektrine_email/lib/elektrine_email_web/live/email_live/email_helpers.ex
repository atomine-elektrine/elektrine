defmodule ElektrineEmailWeb.EmailLive.EmailHelpers do
  @moduledoc """
  Helper functions for working with emails in the LiveView components.
  """
  alias ElektrineEmailWeb.Components.Email.Display

  # Translation
  use Gettext, backend: ElektrineWeb.Gettext

  def format_date(datetime) do
    case datetime do
      %DateTime{} ->
        Calendar.strftime(datetime, "%b %d, %Y %H:%M")

      _ ->
        ""
    end
  end

  def format_datetime(datetime) do
    case datetime do
      %DateTime{} ->
        Calendar.strftime(datetime, "%b %d, %Y at %I:%M %p")

      _ ->
        ""
    end
  end

  def email_return_context(source) when is_map(source) do
    %{
      return_to: Map.get(source, :return_to) || Map.get(source, "return_to") || "inbox",
      return_filter:
        Map.get(source, :return_filter) ||
          Map.get(source, :filter) ||
          Map.get(source, "return_filter") ||
          Map.get(source, "filter") ||
          "inbox",
      return_folder_id:
        normalize_email_return_value(
          Map.get(source, :return_folder_id) ||
            Map.get(source, :folder_id) ||
            Map.get(source, "return_folder_id") ||
            Map.get(source, "folder_id")
        ),
      return_query:
        normalize_email_return_value(
          Map.get(source, :return_query) ||
            Map.get(source, :q) ||
            Map.get(source, "return_query") ||
            Map.get(source, "q")
        )
    }
  end

  def email_return_params(source) do
    context = email_return_context(source)

    [{:return_to, context.return_to}]
    |> maybe_put_email_return_param(
      :filter,
      context.return_to == "inbox" && context.return_filter not in [nil, "", "inbox"],
      context.return_filter
    )
    |> maybe_put_email_return_param(
      :folder_id,
      context.return_to == "folder" && is_binary(context.return_folder_id),
      context.return_folder_id
    )
    |> maybe_put_email_return_param(
      :q,
      context.return_to == "search" && is_binary(context.return_query),
      context.return_query
    )
    |> Enum.reverse()
  end

  def email_return_url(source) do
    context = email_return_context(source)

    case context.return_to do
      "sent" ->
        Elektrine.Paths.email_index_path(tab: "sent")

      "drafts" ->
        Elektrine.Paths.email_index_path(tab: "drafts")

      "spam" ->
        Elektrine.Paths.email_index_path(tab: "spam")

      "trash" ->
        Elektrine.Paths.email_index_path(tab: "trash")

      "archive" ->
        Elektrine.Paths.email_index_path(tab: "archive")

      "contacts" ->
        Elektrine.Paths.email_index_path(tab: "contacts")

      "calendar" ->
        Elektrine.Paths.calendar_path()

      "folder" when is_binary(context.return_folder_id) ->
        Elektrine.Paths.email_index_path(tab: "folder", folder_id: context.return_folder_id)

      "search" when is_binary(context.return_query) ->
        Elektrine.Paths.email_index_path(tab: "search", q: context.return_query)

      "search" ->
        Elektrine.Paths.email_index_path(tab: "search")

      "inbox" when context.return_filter not in [nil, "", "inbox"] ->
        Elektrine.Paths.email_index_path(tab: "inbox", filter: context.return_filter)

      filter
      when filter in ["digest", "ledger", "stack", "boomerang", "aliases", "unread", "read"] ->
        Elektrine.Paths.email_index_path(tab: "inbox", filter: filter)

      _ ->
        Elektrine.Paths.email_index_path(tab: "inbox")
    end
  end

  def email_back_button_text(source) do
    context = email_return_context(source)

    case context.return_to do
      "sent" ->
        gettext("Back to Sent")

      "drafts" ->
        gettext("Back to Drafts")

      "spam" ->
        gettext("Back to Spam")

      "trash" ->
        gettext("Back to Trash")

      "archive" ->
        gettext("Back to Archive")

      "search" ->
        gettext("Back to Search")

      "folder" ->
        gettext("Back to Folder")

      "contacts" ->
        gettext("Back to Contacts")

      "calendar" ->
        gettext("Back to Calendar")

      "digest" ->
        gettext("Back to Digest")

      "ledger" ->
        gettext("Back to Ledger")

      "stack" ->
        gettext("Back to Stack")

      "boomerang" ->
        gettext("Back to Boomerang")

      "inbox" ->
        case context.return_filter do
          "bulk_mail" -> gettext("Back to Bulk Mail")
          "paper_trail" -> gettext("Back to Paper Trail")
          "the_pile" -> gettext("Back to The Pile")
          "digest" -> gettext("Back to Digest")
          "ledger" -> gettext("Back to Ledger")
          "stack" -> gettext("Back to Stack")
          "boomerang" -> gettext("Back to Boomerang")
          "aliases" -> gettext("Back to Aliases")
          "unread" -> gettext("Back to Unread")
          "read" -> gettext("Back to Read")
          _ -> gettext("Back to Inbox")
        end

      _ ->
        gettext("Back to Inbox")
    end
  end

  @doc """
  Formats reply_later_at as relative time (e.g., "in 2 days", "tomorrow", "overdue")
  """
  def format_reply_later_relative(datetime) do
    case datetime do
      %DateTime{} ->
        now = DateTime.utc_now()
        diff_seconds = DateTime.diff(datetime, now)
        diff_days = div(diff_seconds, 86_400)
        diff_hours = div(diff_seconds, 3600)

        cond do
          diff_seconds < 0 ->
            gettext("Overdue")

          diff_hours < 1 ->
            gettext("Within an hour")

          diff_hours < 24 ->
            gettext("Today")

          diff_days == 1 ->
            gettext("Tomorrow")

          diff_days < 7 ->
            gettext("In %{count} days", count: diff_days)

          diff_days < 14 ->
            gettext("Next week")

          diff_days < 30 ->
            gettext("In %{count} weeks", count: div(diff_days, 7))

          true ->
            gettext("In %{count} months", count: div(diff_days, 30))
        end

      _ ->
        ""
    end
  end

  @doc """
  Returns badge color class based on reply_later urgency
  """
  def reply_later_urgency_class(datetime) do
    case datetime do
      %DateTime{} ->
        now = DateTime.utc_now()
        diff_seconds = DateTime.diff(datetime, now)
        diff_hours = div(diff_seconds, 3600)

        cond do
          diff_seconds < 0 -> "badge-error animate-pulse"
          diff_hours < 24 -> "badge-secondary"
          true -> "badge-info"
        end

      _ ->
        "badge-ghost"
    end
  end

  def overdue?(datetime) do
    case datetime do
      %DateTime{} ->
        DateTime.diff(datetime, DateTime.utc_now()) < 0

      _ ->
        false
    end
  end

  def truncate(text, max_length \\ 50), do: Elektrine.TextHelpers.truncate(text, max_length)

  @doc """
  Generate a clean preview from email content, handling HTML and base64 encoding
  """
  def email_preview(message, max_length \\ 150) do
    if private_message?(message) do
      gettext("Unlock your mailbox to preview this message.")
    else
      # Get plain text content
      content =
        cond do
          Elektrine.Strings.present?(message.text_body) ->
            message.text_body
            # Decode quoted-printable encoding first
            |> decode_body()
            |> Display.clean_plain_text_body()
            # Remove image URLs in square brackets like [https://...]
            |> String.replace(~r/\[https?:\/\/[^\]]+\]/i, "")
            # Remove bare URLs
            |> String.replace(~r/https?:\/\/\S+/i, "")
            # Strip any HTML tags that might be in plain text
            |> String.replace(~r/<[^>]+>/, " ")
            |> decode_all_html_entities()

          Elektrine.Strings.present?(message.html_body) ->
            # Simple HTML to text conversion
            message.html_body
            # Decode quoted-printable encoding first
            |> decode_body()
            # Remove script and style blocks entirely (with proper multiline matching)
            |> String.replace(~r/<script\b[^>]*>.*?<\/script>/ims, "")
            |> String.replace(~r/<style\b[^>]*>.*?<\/style>/ims, "")
            # Also remove any CSS that might be at the start (common in email templates)
            |> String.replace(~r/^[\s]*[a-z\s,#\.]+\{[^}]*\}/m, "")
            # Remove image tags and their alt text
            |> String.replace(~r/<img[^>]*>/i, "")
            # Remove links but keep link text
            |> String.replace(~r/<a[^>]*>/i, "")
            |> String.replace(~r/<\/a>/i, " ")
            # Remove all other HTML tags
            |> String.replace(~r/<[^>]+>/, " ")
            # Remove URLs that might be left in the text
            |> String.replace(~r/https?:\/\/\S+/i, "")
            |> decode_all_html_entities()

          true ->
            "(No content available)"
        end

      content
      |> ensure_valid_utf8()
      # Remove any remaining CSS-like patterns (rules with curly braces)
      |> String.replace(~r/[a-z\-]+\s*:\s*[^;}]+;/i, "")
      |> String.replace(~r/\{[^}]*\}/m, " ")
      # Collapse multiple spaces
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      # Skip leading content that looks like CSS comments or directives
      |> String.replace(~r/^\/\*.*?\*\//m, "")
      |> String.trim()
      |> truncate(max_length)
    end
  end

  def private_message?(message) do
    payload = Map.get(message, :client_encrypted_payload)
    is_map(payload) and map_size(payload) > 0
  end

  def private_attachment?(attachment) when is_map(attachment) do
    payload =
      Map.get(attachment, "private_encrypted_payload") ||
        Map.get(attachment, :private_encrypted_payload)

    is_map(payload) and map_size(payload) > 0
  end

  def private_attachment?(_attachment), do: false

  def visible_attachments(%{attachments: attachments}) when is_map(attachments) do
    attachments
    |> Enum.reject(fn {_attachment_id, attachment} -> inline_attachment?(attachment) end)
    |> Enum.into(%{})
  end

  def visible_attachments(_message), do: %{}

  def visible_attachment_count(message), do: map_size(visible_attachments(message))

  def inline_attachment?(attachment) when is_map(attachment) do
    disposition = attachment_disposition(attachment)
    content_id = attachment_content_id(attachment)
    content_type = attachment_content_type(attachment)

    disposition == "inline" or
      (Elektrine.Strings.present?(content_id) and String.starts_with?(content_type, "image/"))
  end

  def inline_attachment?(_attachment), do: false

  defp attachment_disposition(attachment) do
    attachment
    |> attachment_value("disposition", :disposition)
    |> to_string()
    |> String.downcase()
  end

  defp attachment_content_id(attachment),
    do: attachment_value(attachment, "content_id", :content_id)

  defp attachment_content_type(attachment) do
    attachment
    |> attachment_value("content_type", :content_type)
    |> to_string()
    |> String.downcase()
  end

  defp attachment_value(attachment, string_key, atom_key),
    do: Map.get(attachment, string_key) || Map.get(attachment, atom_key) || ""

  defp ensure_valid_utf8(text) do
    if String.valid?(text) do
      text
    else
      # Force to valid UTF-8
      case :unicode.characters_to_binary(text, :utf8, :utf8) do
        {:error, _, _} ->
          # Fallback: keep only ASCII
          text
          |> :binary.bin_to_list()
          |> Enum.filter(fn byte -> byte >= 32 and byte <= 126 end)
          |> :binary.list_to_bin()

        {:incomplete, good, _bad} ->
          good

        good when is_binary(good) ->
          good
      end
    end
  end

  defp decode_all_html_entities(text) do
    text
    # Common named entities
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&mdash;", "-")
    |> String.replace("&ndash;", "-")
    |> String.replace("&hellip;", "...")
    |> String.replace("&copy;", "©")
    |> String.replace("&reg;", "®")
    |> String.replace("&trade;", "™")
    |> String.replace("&ldquo;", "\"")
    |> String.replace("&rdquo;", "\"")
    |> String.replace("&lsquo;", "'")
    |> String.replace("&rsquo;", "'")
    # Numeric entities
    |> String.replace(~r/&#(\d+);/, fn full_match ->
      case Regex.run(~r/&#(\d+);/, full_match) do
        [_, num] ->
          case Integer.parse(num) do
            # Remove problematic combining mark
            {code, ""} when code == 847 ->
              ""

            {code, ""} when code >= 32 and code <= 126 ->
              try do
                <<code::utf8>>
              rescue
                _ -> " "
              end

            _ ->
              " "
          end

        _ ->
          full_match
      end
    end)
    # Hex entities
    |> String.replace(~r/&#x([0-9a-fA-F]+);/, fn full_match ->
      case Regex.run(~r/&#x([0-9a-fA-F]+);/, full_match) do
        [_, hex] ->
          case Integer.parse(hex, 16) do
            # Remove problematic combining mark
            {code, ""} when code == 0x034F ->
              ""

            {code, ""} when code >= 32 and code <= 126 ->
              try do
                <<code::utf8>>
              rescue
                _ -> " "
              end

            _ ->
              " "
          end

        _ ->
          full_match
      end
    end)
  end

  def message_class(message) do
    if message.read do
      "bg-base-200 border-base-300"
    else
      "bg-gradient-to-r from-secondary/5 to-secondary/10 border-secondary/20 shadow-sm"
    end
  end

  @doc """
  Returns an appropriate icon name for a file type based on content type
  """
  def get_file_icon(content_type) when is_binary(content_type) do
    case String.downcase(content_type) do
      "image/" <> _ -> "hero-photo"
      "video/" <> _ -> "hero-play"
      "audio/" <> _ -> "hero-musical-note"
      "text/" <> _ -> "hero-document-text"
      "application/pdf" -> "hero-document"
      "application/zip" <> _ -> "hero-archive-box"
      "application/x-" <> _ -> "hero-archive-box"
      _ -> "hero-document"
    end
  end

  def get_file_icon(_), do: "hero-document"

  @doc """
  Formats file size in human readable format
  """
  def format_file_size(size) when is_integer(size) do
    cond do
      size >= 1024 * 1024 * 1024 -> "#{Float.round(size / (1024 * 1024 * 1024), 1)} GB"
      size >= 1024 * 1024 -> "#{Float.round(size / (1024 * 1024), 1)} MB"
      size >= 1024 -> "#{Float.round(size / 1024, 1)} KB"
      true -> "#{size} B"
    end
  end

  def format_file_size(_), do: "0 B"

  @doc """
  Extracts sender name from email address
  """
  def get_sender_name(from) when is_binary(from) do
    case Regex.run(~r/^(.+?)\s*<(.+)>$/, from) do
      [_, name, _email] -> String.trim(name, "\"")
      _ -> from
    end
  end

  def get_sender_name(_), do: "Unknown"

  @doc """
  Gets sender initials for avatar display
  """
  def get_sender_initials(from) when is_binary(from) do
    name = get_sender_name(from)

    case String.split(name, " ") do
      [first] ->
        String.slice(String.upcase(first), 0, 1)

      [first, last | _] ->
        String.slice(String.upcase(first), 0, 1) <> String.slice(String.upcase(last), 0, 1)

      _ ->
        "?"
    end
  end

  def get_sender_initials(_), do: "?"

  def get_recipient_initials(to) when is_binary(to) do
    # Extract email from potential format like "Name <email@example.com>"
    email_part =
      case String.split(to, "<") do
        [name, _email_part] -> String.trim(name)
        [email] -> email
      end

    # Extract name or use email username
    name_part =
      case email_part do
        "" -> String.split(to, "@") |> List.first() || ""
        name -> name
      end

    name_part
    |> String.split()
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  def get_recipient_initials(_), do: "?"

  def mailbox_addresses(mailbox, user) do
    mailbox
    |> default_sidebar_mailbox_addresses()
    |> then(fn default_addresses ->
      case Elektrine.Domains.email_addresses_for_user(user) do
        [] -> default_addresses
        user_addresses -> normalize_sidebar_mailbox_addresses(mailbox, user_addresses)
      end
    end)
    |> filter_sidebar_mailbox_addresses(mailbox)
  end

  # Public so the ElektrineEmailWeb.Components.Email.Sidebar component can reuse it.
  @doc false
  def default_sidebar_mailbox_addresses(%{email: email}) when is_binary(email) do
    normalize_sidebar_mailbox_addresses(%{email: email}, [
      email | Elektrine.Domains.alternate_local_addresses(email)
    ])
  end

  def default_sidebar_mailbox_addresses(_), do: []

  # Public so the ElektrineEmailWeb.Components.Email.Sidebar component can reuse it.
  @doc false
  def normalize_sidebar_mailbox_addresses(%{email: email}, addresses) when is_binary(email) do
    ([email] ++ List.wrap(addresses))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  def normalize_sidebar_mailbox_addresses(_, addresses) do
    addresses
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp filter_sidebar_mailbox_addresses(addresses, %{email: email}) when is_binary(email) do
    if show_local_development_mailbox_addresses?() do
      addresses
    else
      primary_address = String.downcase(String.trim(email))

      Enum.filter(addresses, fn address ->
        normalized_address = String.downcase(String.trim(address))

        normalized_address == primary_address or
          not local_development_mailbox_address?(normalized_address)
      end)
    end
  end

  defp filter_sidebar_mailbox_addresses(addresses, _), do: addresses

  defp show_local_development_mailbox_addresses? do
    Elektrine.Domains.primary_email_domain()
    |> local_development_email_domain?()
  end

  defp local_development_mailbox_address?(address) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [_local_part, domain] -> local_development_email_domain?(domain)
      _ -> false
    end
  end

  defp local_development_mailbox_address?(_), do: false

  defp local_development_email_domain?(domain) when is_binary(domain) do
    normalized_domain = String.downcase(String.trim(domain))

    normalized_domain == "localhost" or String.ends_with?(normalized_domain, ".localhost")
  end

  defp local_development_email_domain?(_), do: false

  @doc """
  Decode MIME-encoded headers (RFC 2047)
  Format: =?charset?encoding?encoded-text?=

  Note: The mail library doesn't include RFC 2047 header decoding,
  so we keep the custom implementation for subject/header decoding.
  """
  def decode_subject(nil), do: nil
  def decode_subject(""), do: ""

  def decode_subject(text) when is_binary(text) do
    # Remove whitespace between adjacent encoded-words (RFC 2047 section 6.2)
    text = Regex.replace(~r/\?=\s+=\?/, text, "?==?")

    case Regex.scan(~r/=\?([^?]+)\?([BQbq])\?([^?]+)\?=/, text) do
      [] ->
        # No MIME encoding, return as-is
        text

      matches ->
        # Decode each MIME-encoded segment
        Enum.reduce(matches, text, fn [full_match, _charset, encoding, encoded_text], acc ->
          decoded =
            case String.upcase(encoding) do
              "B" ->
                # Base64 encoding
                case Base.decode64(encoded_text) do
                  {:ok, decoded_bytes} -> decoded_bytes
                  :error -> full_match
                end

              "Q" ->
                # Q-encoding (similar to quoted-printable but for headers)
                encoded_text
                # Underscores represent spaces in headers
                |> String.replace("_", " ")
                |> decode_header_qencoding()

              _ ->
                full_match
            end

          String.replace(acc, full_match, decoded)
        end)
    end
  end

  # Decode Q-encoding for headers (similar to quoted-printable)
  defp decode_header_qencoding(text) do
    Regex.replace(~r/=([0-9A-Fa-f]{2})/, text, fn _, hex ->
      case Integer.parse(hex, 16) do
        {byte_value, ""} -> <<byte_value>>
        _ -> "=#{hex}"
      end
    end)
  end

  @doc """
  Decode Quoted-Printable encoding in email body text
  Uses Mail library for robust decoding
  """
  def decode_body(nil), do: nil
  def decode_body(""), do: ""

  def decode_body(text) when is_binary(text) do
    # Check if text contains quoted-printable encoding markers
    if Regex.match?(~r/=[0-9A-Fa-f]{2}|=\r?\n/, text) do
      # Use Mail library's quoted-printable decoder (returns binary directly)
      Mail.Encoders.QuotedPrintable.decode(text)
    else
      # Already decoded, return as-is
      text
    end
  end

  defp maybe_put_email_return_param(params, _key, false, _value), do: params
  defp maybe_put_email_return_param(params, _key, _include?, nil), do: params
  defp maybe_put_email_return_param(params, key, _include?, value), do: [{key, value} | params]

  defp normalize_email_return_value(nil), do: nil
  defp normalize_email_return_value(""), do: nil
  defp normalize_email_return_value(value) when is_binary(value), do: value
  defp normalize_email_return_value(value), do: to_string(value)
end
