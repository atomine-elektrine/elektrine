defmodule ElektrineEmailWeb.EmailLive.Compose do
  use ElektrineEmailWeb, :live_view
  import ElektrineEmailWeb.EmailLive.EmailHelpers
  import ElektrineEmailWeb.Components.Email.Sidebar
  import ElektrineEmailWeb.Components.Platform.ElektrineNav
  import Ecto.Query
  alias Elektrine.Constants
  alias Elektrine.Email
  alias Elektrine.Email.AttachmentStorage
  alias Elektrine.Email.MailboxEncryption
  alias Elektrine.Email.PGP
  alias Elektrine.Email.RateLimiter
  alias Elektrine.Email.SendEmailWorker
  alias Elektrine.Email.Sender
  alias ElektrineEmailWeb.UserErrorHelpers
  require Logger

  @max_email_attachments 5
  @allowed_attachment_types %{
    ".jpg" => ["image/jpeg"],
    ".jpeg" => ["image/jpeg"],
    ".png" => ["image/png"],
    ".gif" => ["image/gif"],
    ".webp" => ["image/webp"],
    ".avif" => ["image/avif"],
    ".heic" => ["image/heic", "image/heif"],
    ".heif" => ["image/heif", "image/heic"],
    ".svg" => ["image/svg+xml", "application/xml", "text/xml"],
    ".pdf" => ["application/pdf"],
    ".doc" => ["application/msword"],
    ".docx" => ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
    ".ppt" => ["application/vnd.ms-powerpoint"],
    ".pptx" => ["application/vnd.openxmlformats-officedocument.presentationml.presentation"],
    ".xls" => ["application/vnd.ms-excel"],
    ".xlsx" => ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
    ".odt" => ["application/vnd.oasis.opendocument.text"],
    ".ods" => ["application/vnd.oasis.opendocument.spreadsheet"],
    ".odp" => ["application/vnd.oasis.opendocument.presentation"],
    ".rtf" => ["application/rtf", "text/rtf"],
    ".txt" => ["text/plain"],
    ".md" => ["text/markdown", "text/plain"],
    ".markdown" => ["text/markdown", "text/plain"],
    ".csv" => ["text/csv", "application/csv", "application/vnd.ms-excel", "text/plain"],
    ".json" => ["application/json", "text/json", "text/plain"],
    ".xml" => ["application/xml", "text/xml", "text/plain"],
    ".log" => ["text/plain"],
    ".zip" => ["application/zip", "application/x-zip-compressed"],
    ".rar" => ["application/vnd.rar", "application/x-rar-compressed"],
    ".7z" => ["application/x-7z-compressed"],
    ".tar" => ["application/x-tar"],
    ".gz" => ["application/gzip", "application/x-gzip"],
    ".tgz" => ["application/gzip", "application/x-gzip"],
    ".bz2" => ["application/x-bzip2"],
    ".xz" => ["application/x-xz"],
    ".mp3" => ["audio/mpeg"],
    ".wav" => ["audio/wav", "audio/x-wav"],
    ".m4a" => ["audio/mp4", "audio/x-m4a"],
    ".ogg" => ["audio/ogg", "application/ogg"],
    ".flac" => ["audio/flac", "audio/x-flac"],
    ".mp4" => ["video/mp4"],
    ".mov" => ["video/quicktime"],
    ".webm" => ["video/webm"],
    ".mkv" => ["video/x-matroska"],
    ".ics" => ["text/calendar", "application/ics"],
    ".vcf" => ["text/vcard", "text/x-vcard"],
    ".eml" => ["message/rfc822"]
  }
  @allowed_attachment_extensions Map.keys(@allowed_attachment_types)
  # Phoenix validates extension filters against MIME's compiled database; use a
  # wildcard for Matroska so stale releases do not crash during LiveView mount.
  @live_upload_accept_filters (@allowed_attachment_extensions -- [".mkv"]) ++ ["video/*"]
  @generic_attachment_content_types ~w(application/octet-stream binary/octet-stream)

  @impl true
  def mount(params, session, socket) do
    user = socket.assigns.current_user
    mailbox = get_or_create_mailbox(user)
    fresh_user = Elektrine.Accounts.get_user!(user.id)
    locale = fresh_user.locale || session["locale"] || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)
    unread_count = Email.unread_count(mailbox.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "mailbox:#{mailbox.id}")
    end

    form_data = build_form_data(params, mailbox)
    page_title = get_page_title(params)

    original_message =
      case Map.get(params, "message_id") do
        nil ->
          nil

        id ->
          get_original_message(id, user.id)
      end

    available_from_addresses = get_available_from_addresses(mailbox, fresh_user)
    from_address = determine_from_address(original_message, mailbox)
    rate_limit_status = RateLimiter.get_rate_limit_status(user.id)
    storage_info = Elektrine.Accounts.Storage.get_storage_info(user.id)
    return_context = email_return_context(params)
    to_tags = parse_email_tags(form_data["to"] || "")
    cc_tags = parse_email_tags(form_data["cc"] || "")
    bcc_tags = parse_email_tags(form_data["bcc"] || "")

    email_attachment_limit =
      if fresh_user.is_admin do
        Constants.max_email_attachment_size_admin()
      else
        Constants.max_email_attachment_size()
      end

    recent_recipients = Elektrine.Email.Contacts.get_recent_recipients(user.id)
    templates = Email.list_templates(user.id)
    custom_folders = Email.list_custom_folders(user.id)

    socket =
      socket
      |> assign(:page_title, page_title)
      |> assign(:templates, templates)
      |> assign(:mailbox, mailbox)
      |> assign(:master_vault, Elektrine.Vault.get(fresh_user.id))
      |> assign(:mailbox_addresses, mailbox_addresses(mailbox, fresh_user))
      |> assign(:from_address, from_address)
      |> assign(:available_from_addresses, available_from_addresses)
      |> assign(:unread_count, unread_count)
      |> assign(:storage_info, storage_info)
      |> assign(:custom_folders, custom_folders)
      |> assign(:mode, Map.get(params, "mode", "compose"))
      |> assign(:original_message_id, Map.get(params, "message_id"))
      |> assign(:original_message, original_message)
      |> assign(:rate_limit_status, rate_limit_status)
      |> assign(:return_to, return_context.return_to)
      |> assign(:return_filter, return_context.return_filter)
      |> assign(:return_folder_id, return_context.return_folder_id)
      |> assign(:return_query, return_context.return_query)
      |> assign(:to_tags, to_tags)
      |> assign(:cc_tags, cc_tags)
      |> assign(:bcc_tags, bcc_tags)
      |> assign(:to_input, "")
      |> assign(:cc_input, "")
      |> assign(:bcc_input, "")
      |> assign(:to_input_error, false)
      |> assign(:cc_input_error, false)
      |> assign(:bcc_input_error, false)
      |> assign(:show_cc_bcc, !Enum.empty?(cc_tags) || !Enum.empty?(bcc_tags))
      |> assign(:form, to_form(form_data))
      |> assign(:attachments_uploaded_count, 0)
      |> assign(:attachments_uploaded_bytes, 0)
      |> assign(:recent_recipients, recent_recipients)
      |> assign(:showing_to_suggestions, false)
      |> assign(:showing_cc_suggestions, false)
      |> assign(:showing_bcc_suggestions, false)
      |> assign(:to_suggestions, [])
      |> assign(:cc_suggestions, [])
      |> assign(:bcc_suggestions, [])
      |> assign(:body_char_count, String.length(form_data["body"] || ""))
      |> assign(:body_word_count, count_words(form_data["body"] || ""))
      |> assign(:body_format, body_format(form_data))
      |> assign(:encryption_mode, form_data["encryption_mode"] || "auto")
      |> assign(:draft_id, form_data["draft_id"])
      |> assign(:draft_status, nil)
      |> assign(:sending, false)
      |> allow_upload(:attachments,
        accept: @live_upload_accept_filters,
        max_entries: 5,
        max_file_size: email_attachment_limit,
        auto_upload: true
      )
      |> assign_encryption_state(form_data["encryption_mode"] || "auto")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page_title = get_page_title(params)

    original_message =
      case Map.get(params, "message_id") do
        nil ->
          nil

        id ->
          get_original_message(id, socket.assigns.current_user.id)
      end

    from_address = determine_from_address(original_message, socket.assigns.mailbox)

    return_context =
      email_return_context(%{
        return_to: Map.get(params, "return_to", socket.assigns.return_to),
        return_filter: Map.get(params, "filter", socket.assigns.return_filter),
        return_folder_id: Map.get(params, "folder_id", socket.assigns[:return_folder_id]),
        return_query: Map.get(params, "q", socket.assigns[:return_query])
      })

    socket =
      if !socket.assigns[:form] || Map.get(params, "mode") != socket.assigns[:mode] do
        form_data = build_form_data(params, socket.assigns.mailbox)
        to_tags = parse_email_tags(form_data["to"] || "")
        cc_tags = parse_email_tags(form_data["cc"] || "")
        bcc_tags = parse_email_tags(form_data["bcc"] || "")

        socket
        |> assign(:form, to_form(form_data))
        |> assign(:body_format, body_format(form_data))
        |> assign(:to_tags, to_tags)
        |> assign(:cc_tags, cc_tags)
        |> assign(:bcc_tags, bcc_tags)
        |> assign(:to_input, "")
        |> assign(:cc_input, "")
        |> assign(:bcc_input, "")
        |> assign(:to_input_error, false)
        |> assign(:cc_input_error, false)
        |> assign(:bcc_input_error, false)
        |> assign(:show_cc_bcc, !Enum.empty?(cc_tags) || !Enum.empty?(bcc_tags))
        |> assign_encryption_state(form_data["encryption_mode"] || "auto")
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:page_title, page_title)
     |> assign(:from_address, from_address)
     |> assign(:mode, Map.get(params, "mode", "compose"))
     |> assign(:original_message_id, Map.get(params, "message_id"))
     |> assign(:original_message, original_message)
     |> assign(:return_to, return_context.return_to)
     |> assign(:return_filter, return_context.return_filter)
     |> assign(:return_folder_id, return_context.return_folder_id)
     |> assign(:return_query, return_context.return_query)}
  end

  @impl true
  def handle_event("show_keyboard_shortcuts", _params, socket) do
    {:noreply, push_event(socket, "show-keyboard-shortcuts", %{})}
  end

  @impl true
  def handle_event("switch_tab", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("change_encryption_mode", params, socket) do
    mode =
      get_in(params, ["email", "encryption_mode"]) || params["encryption_mode"] || params["value"]

    {:noreply, assign_encryption_state(socket, mode)}
  end

  @impl true
  def handle_event("clear_form", _params, socket) do
    {:noreply,
     socket
     |> assign(
       :form,
       to_form(%{
         "to" => "",
         "cc" => "",
         "bcc" => "",
         "subject" => "",
         "body" => "",
         "body_format" => "markdown",
         "encryption_mode" => "auto"
       })
     )
     |> assign(:body_format, "markdown")
     |> assign(:to_tags, [])
     |> assign(:cc_tags, [])
     |> assign(:bcc_tags, [])
     |> assign_encryption_state("auto")
     |> notify_info("Form cleared")}
  end

  @impl true
  def handle_event("apply_template", %{"template_id" => ""}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("apply_template", %{"template_id" => template_id}, socket) do
    user_id = socket.assigns.current_user.id

    with {:ok, template_id} <- parse_positive_int(template_id),
         template when not is_nil(template) <- Email.get_template(template_id, user_id) do
      current_form = socket.assigns.form.params || %{}

      updated_form =
        current_form
        |> Map.put("subject", template.subject || current_form["subject"] || "")
        |> put_template_body(socket.assigns.mode, template.body || "")

      {:noreply,
       socket
       |> assign(:form, to_form(updated_form))
       |> assign(:body_char_count, String.length(template.body || ""))
       |> assign(:body_word_count, count_words(template.body || ""))
       |> put_flash(:info, "Template \"#{template.name}\" applied")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Template not found")}
    end
  end

  @impl true
  def handle_event("change_from_address", params, socket) do
    from_address = params["from_address"] || params["value"]
    {:noreply, assign(socket, :from_address, from_address)}
  end

  @impl true
  def handle_event("validate", %{"email" => email_params}, socket) do
    socket = validate_attachments(socket)
    email_params = merge_current_form_params(socket, email_params)
    email_params = put_body_format(email_params, socket.assigns.body_format)
    body = email_params["body"] || email_params["new_message"] || ""
    word_count = count_words(body)

    {:noreply,
     socket
     |> assign(:form, to_form(email_params))
     |> assign(:body_format, body_format(email_params, socket.assigns.body_format))
     |> assign(:body_word_count, word_count)
     |> assign_encryption_state(email_params["encryption_mode"])}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    socket = validate_attachments(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_and_autosave", %{"email" => email_params}, socket) do
    socket = validate_attachments(socket)
    email_params = merge_current_form_params(socket, email_params)
    email_params = put_body_format(email_params, socket.assigns.body_format)
    body = email_params["body"] || email_params["new_message"] || ""
    word_count = count_words(body)

    socket =
      socket
      |> assign(:form, to_form(email_params))
      |> assign(:body_format, body_format(email_params, socket.assigns.body_format))
      |> assign(:body_word_count, word_count)
      |> assign_encryption_state(email_params["encryption_mode"])

    has_content =
      Elektrine.Strings.present?(email_params["subject"]) ||
        Elektrine.Strings.present?(email_params["body"]) ||
        Elektrine.Strings.present?(email_params["new_message"])

    if has_content do
      socket = assign(socket, :draft_status, :saving)
      send(self(), {:autosave_draft, email_params})
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate_and_autosave", _params, socket) do
    socket = validate_attachments(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  @impl true
  def handle_event("remove_tag", %{"field" => field, "email" => email}, socket) do
    socket =
      case field do
        "to" -> assign(socket, :to_tags, List.delete(socket.assigns.to_tags, email))
        "cc" -> assign(socket, :cc_tags, List.delete(socket.assigns.cc_tags, email))
        "bcc" -> assign(socket, :bcc_tags, List.delete(socket.assigns.bcc_tags, email))
        _ -> socket
      end

    {:noreply, assign_encryption_state(socket)}
  end

  @impl true
  def handle_event("update_tag_input", %{"field" => field, "value" => value}, socket) do
    suggestions =
      if String.length(value) >= 1 do
        query = String.downcase(value)

        Enum.filter(socket.assigns.recent_recipients, fn r ->
          String.contains?(String.downcase(r.email), query) ||
            String.contains?(String.downcase(r.name || ""), query)
        end)
        |> Enum.take(5)
      else
        []
      end

    socket =
      case field do
        "to" ->
          assign(socket, to_suggestions: suggestions, showing_to_suggestions: suggestions != [])

        "cc" ->
          assign(socket, cc_suggestions: suggestions, showing_cc_suggestions: suggestions != [])

        "bcc" ->
          assign(socket, bcc_suggestions: suggestions, showing_bcc_suggestions: suggestions != [])

        _ ->
          socket
      end

    socket =
      if String.contains?(value, [",", ";"]) do
        emails = String.split(value, ~r/[,;]/)

        {tags_key, input_key, error_key} =
          case field do
            "to" -> {:to_tags, :to_input, :to_input_error}
            "cc" -> {:cc_tags, :cc_input, :cc_input_error}
            "bcc" -> {:bcc_tags, :bcc_input, :bcc_input_error}
            _ -> {nil, nil, nil}
          end

        if tags_key do
          current_tags = Map.get(socket.assigns, tags_key)

          {tags, last_input, has_invalid} =
            Enum.reduce(emails, {current_tags, "", false}, fn email, {tags, _, invalid} ->
              email = String.trim(email)

              cond do
                email == "" -> {tags, "", invalid}
                valid_email?(email) && email not in tags -> {tags ++ [email], "", invalid}
                valid_email?(email) -> {tags, "", invalid}
                true -> {tags, email, true}
              end
            end)

          socket
          |> assign(tags_key, tags)
          |> assign(input_key, last_input)
          |> assign(error_key, has_invalid)
          |> maybe_clear_tag_input(field, last_input)
        else
          socket
        end
      else
        case field do
          "to" -> socket |> assign(:to_input, value) |> assign(:to_input_error, false)
          "cc" -> socket |> assign(:cc_input, value) |> assign(:cc_input_error, false)
          "bcc" -> socket |> assign(:bcc_input, value) |> assign(:bcc_input_error, false)
          _ -> socket
        end
      end

    {:noreply, assign_encryption_state(socket)}
  end

  @impl true
  def handle_event("select_suggestion", %{"field" => field, "email" => email}, socket) do
    suggestions =
      case field do
        "to" -> socket.assigns.to_suggestions
        "cc" -> socket.assigns.cc_suggestions
        "bcc" -> socket.assigns.bcc_suggestions
        _ -> []
      end

    is_valid_suggestion = Enum.any?(suggestions, fn s -> s.email == email end)

    if is_valid_suggestion do
      {tags_key, input_key, error_key, suggestions_key, showing_key} =
        case field do
          "to" ->
            {:to_tags, :to_input, :to_input_error, :to_suggestions, :showing_to_suggestions}

          "cc" ->
            {:cc_tags, :cc_input, :cc_input_error, :cc_suggestions, :showing_cc_suggestions}

          "bcc" ->
            {:bcc_tags, :bcc_input, :bcc_input_error, :bcc_suggestions, :showing_bcc_suggestions}

          _ ->
            {nil, nil, nil, nil, nil}
        end

      if tags_key do
        current_tags = Map.get(socket.assigns, tags_key)

        new_tags =
          if email in current_tags do
            current_tags
          else
            current_tags ++ [email]
          end

        {:noreply,
         socket
         |> assign(tags_key, new_tags)
         |> assign(input_key, "")
         |> assign(error_key, false)
         |> assign(suggestions_key, [])
         |> assign(showing_key, false)
         |> maybe_clear_tag_input(field)
         |> assign_encryption_state()}
      else
        {:noreply, socket}
      end
    else
      Logger.warning("SECURITY: Rejected suggestion not in list - field=#{field}, email=#{email}")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("tag_input_blur", %{"field" => field}, socket) do
    current_input =
      case field do
        "to" -> socket.assigns.to_input
        "cc" -> socket.assigns.cc_input
        "bcc" -> socket.assigns.bcc_input
        _ -> ""
      end

    should_process = current_input != ""

    socket =
      case field do
        "to" -> assign(socket, showing_to_suggestions: false)
        "cc" -> assign(socket, showing_cc_suggestions: false)
        "bcc" -> assign(socket, showing_bcc_suggestions: false)
        _ -> socket
      end

    if should_process do
      {:noreply, add_tag_from_input(socket, field)}
    else
      {:noreply, assign_encryption_state(socket)}
    end
  end

  @impl true
  def handle_event("tag_input_keydown", %{"field" => field, "key" => "Enter"}, socket) do
    {:noreply, add_tag_from_input(socket, field)}
  end

  @impl true
  def handle_event("tag_input_keydown", %{"field" => field, "key" => "Backspace"}, socket) do
    socket =
      case field do
        "to" ->
          if socket.assigns.to_input == "" && socket.assigns.to_tags != [] do
            assign(socket, :to_tags, List.delete_at(socket.assigns.to_tags, -1))
          else
            socket
          end

        "cc" ->
          if socket.assigns.cc_input == "" && socket.assigns.cc_tags != [] do
            assign(socket, :cc_tags, List.delete_at(socket.assigns.cc_tags, -1))
          else
            socket
          end

        "bcc" ->
          if socket.assigns.bcc_input == "" && socket.assigns.bcc_tags != [] do
            assign(socket, :bcc_tags, List.delete_at(socket.assigns.bcc_tags, -1))
          else
            socket
          end

        _ ->
          socket
      end

    {:noreply, assign_encryption_state(socket)}
  end

  @impl true
  def handle_event("tag_input_keydown", %{"field" => _field}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_cc_bcc", _params, socket) do
    {:noreply, assign(socket, :show_cc_bcc, !socket.assigns.show_cc_bcc)}
  end

  @impl true
  def handle_event("save", %{"action" => "save_draft", "email" => email_params}, socket) do
    handle_event("save_draft", %{"email" => email_params}, socket)
  end

  @impl true
  def handle_event("save", %{"email" => email_params}, socket) do
    user = socket.assigns.current_user
    _mailbox = socket.assigns.mailbox
    mode = socket.assigns.mode
    original_message = Map.get(socket.assigns, :original_message)
    socket = validate_attachments(socket)
    email_params = put_body_format(email_params, socket.assigns.body_format)
    body_format = body_format(email_params, socket.assigns.body_format)
    socket = socket |> assign(:sending, true) |> assign(:body_format, body_format)

    if blank_reply?(mode, email_params) do
      {:noreply,
       socket
       |> assign(:sending, false)
       |> assign(:form, to_form(email_params))
       |> notify_error("Type a reply before sending.")}
    else
      {text_body, html_body} =
        if mode in ["reply", "reply_all", "forward"] && email_params["new_message"] do
          new_message = normalize_message_body(email_params["new_message"])
          combined_text = combine_reply_text(new_message, email_params["body"])

          combined_html =
            if body_format == "plaintext" do
              nil
            else
              if original_message && Elektrine.Strings.present?(original_message.html_body) do
                new_message_html = markdown_to_html(new_message)

                if mode == "reply" do
                  date_str = format_date_for_quote(original_message.inserted_at)

                  sender_text =
                    if original_message.status == "sent" do
                      "you"
                    else
                      original_message.from
                    end

                  new_message_html <> "<br><br>
<div style=\"color: #666; border-left: 2px solid #ccc; padding-left: 10px; margin-left: 5px;\">
  On #{date_str}, #{sender_text} wrote:<br>
  #{original_message.html_body}
</div>
"
                else
                  date_str = format_date_for_quote(original_message.inserted_at)

                  attachment_html =
                    if original_message.attachments && is_map(original_message.attachments) &&
                         map_size(original_message.attachments) > 0 do
                      attachment_list =
                        original_message.attachments
                        |> Enum.map(fn {_key, attachment} ->
                          filename = Map.get(attachment, "filename", "unknown")
                          size = Map.get(attachment, "size", "unknown")
                          "<li>#{filename} (#{size} bytes)</li>"
                        end)
                        |> Enum.map_join("", & &1)

                      "<br><strong>Attachments:</strong><ul style='margin: 5px 0 10px 20px;'>#{attachment_list}</ul>"
                    else
                      ""
                    end

                  new_message_html <> "<br><br>
<div style=\"border: 1px solid #ccc; padding: 15px; margin: 10px 0; background-color: #f9f9f9;\">
  <div style=\"color: #666; margin-bottom: 10px;\">
    ---------- Forwarded message ----------<br>
    <strong>From:</strong> #{original_message.from}<br>
    <strong>To:</strong> #{original_message.to}<br>
    <strong>Date:</strong> #{date_str}<br>
    <strong>Subject:</strong> #{original_message.subject}#{attachment_html}
  </div>
  <div style=\"margin-top: 15px;\">
    #{original_message.html_body}
  </div>
</div>
"
                end
              else
                markdown_to_html(combined_text)
              end
            end

          {combined_text, combined_html}
        else
          text = email_params["body"] || ""
          text_with_signature = append_signature(text, socket.assigns.current_user)
          html = html_body_for_format(text_with_signature, body_format)
          {text_with_signature, html}
        end

      email_attrs = %{
        from: socket.assigns.from_address,
        to: Enum.join(socket.assigns.to_tags, ", "),
        cc: Enum.join(socket.assigns.cc_tags, ", "),
        bcc: Enum.join(socket.assigns.bcc_tags, ", "),
        subject: email_params["subject"],
        text_body: text_body,
        html_body: html_body,
        encryption_mode: email_params["encryption_mode"] || socket.assigns.encryption_mode
      }

      temp_message_id = "temp_#{System.system_time(:millisecond)}"
      mailbox_id = socket.assigns.mailbox.id

      # Check the attachment rate limit before consuming uploads: it avoids
      # the storage upload work, and the entries stay attached to the form so
      # the user doesn't lose them when the send is rejected.
      upload_rate_limited =
        socket.assigns.uploads.attachments.entries != [] && attachment_rate_limited?(user.id)

      uploaded_attachments =
        if upload_rate_limited do
          []
        else
          consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
            file_content = File.read!(path)
            attachment_id = "temp_#{System.system_time(:millisecond)}_#{:rand.uniform(999_999)}"

            metadata = %{
              "filename" => entry.client_name,
              "content_type" => entry.client_type,
              "size" => entry.client_size
            }

            s3_result =
              try do
                Task.await(
                  Task.async(fn ->
                    AttachmentStorage.upload_attachment(
                      mailbox_id,
                      temp_message_id,
                      attachment_id,
                      file_content,
                      metadata
                    )
                  end),
                  5000
                )
              catch
                :exit, _ -> {:error, :timeout}
              end

            case s3_result do
              {:ok, s3_metadata} ->
                attachment =
                  Map.merge(
                    %{
                      "filename" => entry.client_name,
                      "content_type" => entry.client_type,
                      "size" => entry.client_size,
                      "encoding" => "base64"
                    },
                    s3_metadata
                  )

                attachment_with_data = Map.put(attachment, "data", Base.encode64(file_content))
                {:ok, {attachment, attachment_with_data}}

              {:error, reason} ->
                Logger.warning("S3 upload failed (#{inspect(reason)}), using database storage")
                base64_data = Base.encode64(file_content)

                attachment = %{
                  "filename" => entry.client_name,
                  "content_type" => entry.client_type,
                  "size" => entry.client_size,
                  "encoding" => "base64",
                  "data" => base64_data
                }

                {:ok, {attachment, attachment}}
            end
          end)
        end

      successful_uploads =
        Enum.filter(uploaded_attachments, fn
          {_db, _email} -> true
          _ -> false
        end)

      {db_attachments, email_attachments} =
        if successful_uploads != [] do
          Enum.unzip(successful_uploads)
        else
          {[], []}
        end

      private_forward_attachments =
        parse_private_forward_attachments(email_params, mode, original_message, user)

      {all_db_attachments, all_email_attachments} =
        if mode == "forward" && original_message && original_message.attachments do
          forwarded_with_data =
            original_message.attachments
            |> Map.values()
            |> Enum.reject(&MailboxEncryption.attachment_encrypted?/1)
            |> Enum.map(fn att ->
              att_with_data =
                if AttachmentStorage.stored_attachment?(att) do
                  case AttachmentStorage.download_attachment(att) do
                    {:ok, content} ->
                      Map.put(att, "data", Base.encode64(content))

                    {:error, _} ->
                      Logger.warning("Failed to download forwarded attachment from storage")
                      att
                  end
                else
                  att
                end

              {att, att_with_data}
            end)

          {fwd_db, fwd_email} =
            if forwarded_with_data == [] do
              {[], []}
            else
              Enum.unzip(forwarded_with_data)
            end

          {
            db_attachments ++ fwd_db ++ private_forward_attachments,
            email_attachments ++ fwd_email ++ private_forward_attachments
          }
        else
          {db_attachments ++ private_forward_attachments,
           email_attachments ++ private_forward_attachments}
        end

      email_attrs =
        if all_email_attachments != [] do
          attachments_map =
            all_email_attachments
            |> Enum.with_index()
            |> Enum.into(%{}, fn {attachment, index} -> {to_string(index), attachment} end)

          Map.put(email_attrs, :attachments, attachments_map)
        else
          email_attrs
        end

      email_attrs =
        if mode in ["reply", "reply_all"] && original_message do
          reply_to_id =
            if original_message.metadata &&
                 Map.has_key?(original_message.metadata, "original_message_id") do
              original_message.metadata["original_message_id"]
            else
              original_message.message_id
            end

          references = build_reply_references(original_message, reply_to_id)

          email_attrs
          |> Map.put(:in_reply_to, reply_to_id)
          |> maybe_put_reply_references(references)
        else
          email_attrs
        end

      db_attachments_map =
        if all_db_attachments != [] do
          all_db_attachments
          |> Enum.with_index()
          |> Enum.into(%{}, fn {attachment, index} -> {to_string(index), attachment} end)
        else
          nil
        end

      send_at = parse_scheduled_send_at(email_params["send_at"])

      send_result =
        cond do
          upload_rate_limited ->
            {:error, :attachment_rate_limit_exceeded}

          length(all_db_attachments) > @max_email_attachments ->
            {:error, :too_many_attachments}

          any_attachment_too_large?(all_db_attachments, user) ->
            {:error, :attachment_too_large}

          all_db_attachments != [] && attachment_rate_limited?(user.id) ->
            {:error, :attachment_rate_limit_exceeded}

          scheduled_send?(send_at) ->
            SendEmailWorker.enqueue(user.id, email_attrs, db_attachments_map,
              scheduled_for: send_at
            )

          true ->
            Sender.send_email(user.id, email_attrs, db_attachments_map)
        end

      case send_result do
        {:ok, _message} ->
          Elektrine.Accounts.Storage.update_user_storage(user.id)

          if draft_id = socket.assigns[:draft_id] do
            Email.delete_draft(draft_id, socket.assigns.mailbox.id)
          end

          updated_status = RateLimiter.get_rate_limit_status(user.id)
          return_url = email_return_url(socket.assigns)

          message =
            if scheduled_send?(send_at) do
              "Email scheduled for #{Calendar.strftime(send_at, "%b %-d, %Y %H:%M UTC")}."
            else
              "Email sent successfully!"
            end

          {:noreply,
           socket
           |> assign(:rate_limit_status, updated_status)
           |> notify_info(message)
           |> push_navigate(to: return_url)}

        {:error, :rate_limit_exceeded} ->
          rate_limit_message = build_rate_limit_error_message(user.id)

          {:noreply,
           socket
           |> assign(:sending, false)
           |> notify_error(rate_limit_message)
           |> assign(:form, to_form(email_params))}

        {:error, :attachment_rate_limit_exceeded} ->
          {:noreply,
           socket
           |> assign(:sending, false)
           |> notify_error("Attachment upload limit exceeded (max 20 files per hour)")
           |> assign(:form, to_form(email_params))}

        {:error, :too_many_attachments} ->
          {:noreply,
           socket
           |> assign(:sending, false)
           |> notify_error("Too many attachments (max #{@max_email_attachments})")
           |> assign(:form, to_form(email_params))}

        {:error, :attachment_too_large} ->
          {:noreply,
           socket
           |> assign(:sending, false)
           |> notify_error("One or more attachments exceed the attachment size limit")
           |> assign(:form, to_form(email_params))}

        {:error, :storage_limit_exceeded} ->
          storage_limit =
            case socket.assigns[:storage_info] do
              %{limit_formatted: limit_formatted} when is_binary(limit_formatted) ->
                limit_formatted

              _ ->
                case Elektrine.Accounts.Storage.get_storage_info(user.id) do
                  %{limit_formatted: limit_formatted} when is_binary(limit_formatted) ->
                    limit_formatted

                  _ ->
                    "configured limit"
                end
            end

          {:noreply,
           socket
           |> assign(:sending, false)
           |> notify_error(
             "Cannot send email: your mailbox storage limit (#{storage_limit}) has been exceeded. Please delete some emails first."
           )
           |> assign(:form, to_form(email_params))}

        {:error, {:missing_pgp_keys, missing_recipients}} ->
          {:noreply,
           socket
           |> assign(:sending, false)
           |> notify_error(missing_pgp_keys_message(missing_recipients))
           |> assign(:form, to_form(email_params))}

        {:error, :pgp_attachments_unsupported} ->
          {:noreply,
           socket
           |> assign(:sending, false)
           |> notify_error(
             "Required encryption cannot protect regular attachments yet. Remove attachments, attach already-encrypted .pgp/.gpg/.asc files, or switch to Encrypt when possible."
           )
           |> assign(:form, to_form(email_params))}

        {:error, :gpg_unavailable} ->
          {:noreply,
           socket
           |> assign(:sending, false)
           |> notify_error("OpenPGP delivery is not available on this server right now.")
           |> assign(:form, to_form(email_params))}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:sending, false)
           |> notify_error(
             UserErrorHelpers.reason_message(reason, "Failed to send email. Please try again.")
           )
           |> assign(:form, to_form(email_params))}
      end
    end
  end

  @impl true
  def handle_event("save_draft", %{"email" => email_params}, socket) do
    mailbox = socket.assigns.mailbox
    draft_id = socket.assigns[:draft_id]

    draft_attrs = %{
      mailbox_id: mailbox.id,
      from: socket.assigns.from_address,
      to: Enum.join(socket.assigns.to_tags, ", "),
      cc: Enum.join(socket.assigns.cc_tags, ", "),
      bcc: Enum.join(socket.assigns.bcc_tags, ", "),
      subject: email_params["subject"] || "",
      text_body: draft_body(email_params, socket.assigns.mode),
      html_body:
        html_body_for_format(
          draft_body(email_params, socket.assigns.mode),
          body_format(email_params, socket.assigns.body_format)
        ),
      metadata: %{"body_format" => body_format(email_params, socket.assigns.body_format)},
      status: "draft"
    }

    case Email.save_draft(draft_attrs, draft_id) do
      {:ok, saved_draft} ->
        {:noreply, socket |> assign(:draft_id, saved_draft.id) |> notify_info("Draft saved")}

      {:error, _reason} ->
        {:noreply, socket |> notify_error("Failed to save draft")}
    end
  end

  defp merge_current_form_params(socket, params) when is_map(params) do
    current_params =
      case socket.assigns[:form] do
        %{params: form_params} when is_map(form_params) -> form_params
        _ -> %{}
      end

    merged_params = Map.merge(current_params, params)

    preserve_original_body_params(socket.assigns.mode, current_params, params, merged_params)
  end

  defp preserve_original_body_params(mode, current_params, params, merged_params)
       when mode in ["reply", "reply_all", "forward"] do
    original_body = current_params["body"] || ""

    merged_params
    |> Map.put("body", original_body)
    |> maybe_move_body_param_to_new_message(original_body, params)
  end

  defp preserve_original_body_params(_mode, _current_params, _params, merged_params),
    do: merged_params

  defp maybe_move_body_param_to_new_message(merged_params, original_body, params) do
    with false <- Map.has_key?(params, "new_message"),
         true <- Map.has_key?(params, "body"),
         body when is_binary(body) <- params["body"],
         true <- normalize_message_body(body) != normalize_message_body(original_body) do
      Map.put(merged_params, "new_message", body)
    else
      _ -> merged_params
    end
  end

  defp parse_scheduled_send_at(nil), do: nil
  defp parse_scheduled_send_at(""), do: nil

  defp parse_scheduled_send_at(value) when is_binary(value) do
    value
    |> NaiveDateTime.from_iso8601()
    |> case do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  defp parse_scheduled_send_at(_value), do: nil

  defp scheduled_send?(%DateTime{} = send_at),
    do: DateTime.compare(send_at, DateTime.utc_now()) == :gt

  defp scheduled_send?(_send_at), do: false

  defp add_tag_from_input(socket, field) do
    {current_input, tags_key, error_key, input_key} =
      case field do
        "to" -> {socket.assigns.to_input, :to_tags, :to_input_error, :to_input}
        "cc" -> {socket.assigns.cc_input, :cc_tags, :cc_input_error, :cc_input}
        "bcc" -> {socket.assigns.bcc_input, :bcc_tags, :bcc_input_error, :bcc_input}
        _ -> {nil, nil, nil, nil}
      end

    if current_input && tags_key do
      email = String.trim(current_input)
      current_tags = Map.get(socket.assigns, tags_key)

      cond do
        email == "" ->
          socket |> assign(error_key, false) |> assign_encryption_state()

        valid_email?(email) && email not in current_tags ->
          socket
          |> assign(tags_key, current_tags ++ [email])
          |> assign(input_key, "")
          |> assign(error_key, false)
          |> maybe_clear_tag_input(field)
          |> assign_encryption_state()

        valid_email?(email) ->
          socket
          |> assign(input_key, "")
          |> assign(error_key, false)
          |> maybe_clear_tag_input(field)
          |> assign_encryption_state()

        true ->
          socket
          |> assign(input_key, "")
          |> assign(error_key, false)
          |> maybe_clear_tag_input(field)
          |> assign_encryption_state()
      end
    else
      socket
    end
  end

  defp maybe_clear_tag_input(socket, field, input_value \\ "")

  defp maybe_clear_tag_input(socket, field, input_value) when input_value in [nil, ""] do
    push_event(socket, "clear-tag-input", %{field: field})
  end

  defp maybe_clear_tag_input(socket, _field, _input_value), do: socket

  @impl true
  def handle_info({:user_updated, updated_user}, socket) do
    if socket.assigns.current_user.id == updated_user.id do
      refreshed_user = Elektrine.Accounts.get_user!(updated_user.id)
      rate_limit_status = RateLimiter.get_rate_limit_status(updated_user.id)

      {:noreply,
       socket
       |> assign(:current_user, refreshed_user)
       |> assign(:rate_limit_status, rate_limit_status)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:storage_updated, %{storage_used_bytes: _used_bytes, user_id: user_id}},
        socket
      ) do
    if socket.assigns.current_user.id == user_id do
      storage_info = Elektrine.Accounts.Storage.get_storage_info(user_id)
      {:noreply, assign(socket, :storage_info, storage_info)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:notification_count_updated, _new_count} = msg, socket) do
    ElektrineWeb.Live.NotificationHelpers.handle_notification_count_update(msg, socket)
  end

  def handle_info({:unread_count_updated, new_count}, socket) do
    {:noreply, assign(socket, :unread_count, new_count)}
  end

  def handle_info({:new_email, _message}, socket) do
    mailbox = socket.assigns.mailbox
    unread_count = Email.unread_count(mailbox.id)
    {:noreply, assign(socket, :unread_count, unread_count)}
  end

  def handle_info({:mailbox_storage_updated, _update}, socket) do
    {:noreply, socket}
  end

  def handle_info({:autosave_draft, email_params}, socket) do
    mailbox = socket.assigns.mailbox
    draft_id = socket.assigns[:draft_id]

    # In reply/forward modes the user's text lives in "new_message", not
    # "body" - draft_body/2 picks the right field so autosave doesn't lose it.
    body = draft_body(email_params, socket.assigns.mode)

    draft_attrs = %{
      mailbox_id: mailbox.id,
      from: socket.assigns.from_address,
      to: Enum.join(socket.assigns.to_tags, ", "),
      cc: Enum.join(socket.assigns.cc_tags, ", "),
      bcc: Enum.join(socket.assigns.bcc_tags, ", "),
      subject: email_params["subject"] || "",
      text_body: body,
      html_body:
        html_body_for_format(
          body,
          body_format(email_params, socket.assigns.body_format)
        ),
      metadata: %{"body_format" => body_format(email_params, socket.assigns.body_format)},
      status: "draft"
    }

    case Email.save_draft(draft_attrs, draft_id) do
      {:ok, saved_draft} ->
        {:noreply, socket |> assign(:draft_id, saved_draft.id) |> assign(:draft_status, :saved)}

      {:error, _reason} ->
        {:noreply, assign(socket, :draft_status, :error)}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp get_or_create_mailbox(user) do
    case Email.get_user_mailbox(user.id) do
      nil ->
        {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
        mailbox

      mailbox ->
        mailbox
    end
  end

  defp build_form_data(params, mailbox) do
    case {Map.get(params, "mode"), Map.get(params, "message_id"), Map.get(params, "draft_id")} do
      {"reply", message_id, _} when not is_nil(message_id) ->
        build_reply_data(message_id, mailbox, :sender_only)

      {"reply_all", message_id, _} when not is_nil(message_id) ->
        build_reply_data(message_id, mailbox, :all_recipients)

      {"forward", message_id, _} when not is_nil(message_id) ->
        build_forward_data(message_id, mailbox)

      {"draft", _, draft_id} when not is_nil(draft_id) ->
        build_draft_data(draft_id, mailbox)

      _ ->
        %{
          "to" => Map.get(params, "to", ""),
          "cc" => Map.get(params, "cc", ""),
          "bcc" => Map.get(params, "bcc", ""),
          "subject" => Map.get(params, "subject", ""),
          "body" => Map.get(params, "body", ""),
          "body_format" => body_format(params),
          "encryption_mode" => Map.get(params, "encryption_mode", "auto")
        }
    end
  end

  defp build_draft_data(draft_id, mailbox) do
    with {:ok, draft_id} <- parse_positive_int(draft_id),
         draft when not is_nil(draft) <- Email.get_draft(draft_id, mailbox.id) do
      %{
        "to" => draft.to || "",
        "cc" => draft.cc || "",
        "bcc" => draft.bcc || "",
        "subject" => draft.subject || "",
        "body" => draft.text_body || "",
        "body_format" => body_format(draft.metadata || %{}),
        "encryption_mode" => "auto",
        "draft_id" => draft.id
      }
    else
      nil ->
        Logger.warning("Draft not found: #{inspect(draft_id)}")
        empty_draft_data()

      :error ->
        Logger.warning("Invalid draft id: #{inspect(draft_id)}")
        empty_draft_data()
    end
  end

  defp build_reply_data(message_id, mailbox, reply_type) do
    with {:ok, message_id} <- parse_positive_int(message_id),
         {:ok, message} <- Email.get_user_message(message_id, mailbox.user_id) do
      subject =
        case message.subject do
          nil ->
            "Re: "

          subj when is_binary(subj) ->
            if String.starts_with?(subj, "Re: ") do
              subj
            else
              "Re: #{subj}"
            end
        end

      quoted_body = format_quoted_reply(message)
      {reply_to, reply_cc} = build_reply_recipients(message, mailbox, reply_type)

      %{
        "to" => reply_to,
        "cc" => reply_cc,
        "bcc" => "",
        "subject" => subject,
        "body" => quoted_body,
        "body_format" => "markdown",
        "new_message" => ""
      }
    else
      _ ->
        Logger.warning("Message not found or access denied for reply: #{inspect(message_id)}")
        empty_compose_data()
    end
  end

  defp build_forward_data(message_id, mailbox) do
    with {:ok, message_id} <- parse_positive_int(message_id),
         {:ok, message} <- Email.get_user_message(message_id, mailbox.user_id) do
      subject =
        case message.subject do
          nil ->
            "Fwd: "

          subj when is_binary(subj) ->
            if String.starts_with?(subj, "Fwd: ") do
              subj
            else
              "Fwd: #{subj}"
            end
        end

      forwarded_body = format_forwarded_message(message)

      %{
        "to" => "",
        "cc" => "",
        "bcc" => "",
        "subject" => subject,
        "body" => forwarded_body,
        "body_format" => "markdown"
      }
    else
      _ ->
        empty_compose_data()
    end
  end

  defp get_original_message(message_id, user_id) do
    with {:ok, message_id} <- parse_positive_int(message_id),
         {:ok, message} <- Email.get_user_message(message_id, user_id) do
      message
    else
      _ -> nil
    end
  end

  defp empty_draft_data do
    Map.put(empty_compose_data(), "draft_id", nil)
  end

  defp empty_compose_data do
    %{
      "to" => "",
      "cc" => "",
      "bcc" => "",
      "subject" => "",
      "body" => "",
      "body_format" => "markdown"
    }
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_positive_int(_value), do: :error

  defp format_quoted_reply(message) do
    if Map.get(message, :client_encrypted_payload) do
      "\n\n[Encrypted mailbox content is not available for quoted replies in compose yet.]\n"
    else
      date_str = format_date_for_quote(message.inserted_at)

      sender_text =
        if message.status == "sent" do
          "you"
        else
          message.from
        end

      text_body = message.text_body || strip_html_tags(message.html_body || "")
      "

On #{date_str}, #{sender_text} wrote:
#{quote_message_body(text_body)}
"
    end
  end

  defp format_forwarded_message(message) do
    if Map.get(message, :client_encrypted_payload) do
      "\n\n---------- Forwarded message ----------\n#{message.from}\n[Encrypted mailbox content is not available for forwarding in compose yet.]\n"
    else
      date_str = format_date_for_quote(message.inserted_at)
      text_body = message.text_body || strip_html_tags(message.html_body || "")

      attachment_info =
        if message.attachments && is_map(message.attachments) && map_size(message.attachments) > 0 do
          attachment_list =
            message.attachments
            |> Enum.map(fn {_key, attachment} ->
              filename = Map.get(attachment, "filename", "unknown")
              size = Map.get(attachment, "size", "unknown")
              "- #{filename} (#{size} bytes)"
            end)
            |> Enum.map_join("\n", & &1)

          "
Attachments:
#{attachment_list}
"
        else
          ""
        end

      "

---------- Forwarded message ----------
From: #{message.from}
To: #{message.to}
Date: #{date_str}
Subject: #{message.subject}#{attachment_info}

#{text_body}
"
    end
  end

  defp parse_private_forward_attachments(email_params, "forward", original_message, user)
       when is_map(email_params) and not is_nil(original_message) do
    case Map.get(email_params, "private_forward_attachments") do
      raw when is_binary(raw) and raw != "" ->
        with {:ok, attachments} when is_list(attachments) <- Jason.decode(raw),
             {:ok, verified} <-
               verify_private_forward_attachments(attachments, original_message, user) do
          verified
        else
          _ ->
            Logger.warning("Rejected invalid private forwarded attachments")
            []
        end

      _ ->
        []
    end
  end

  defp parse_private_forward_attachments(_email_params, _mode, _original_message, _user), do: []

  defp verify_private_forward_attachments(attachments, original_message, user) do
    original_attachments = original_message.attachments || %{}
    max_size = email_attachment_limit(user)

    attachments
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn attachment, {:ok, verified, seen_ids} ->
      with {:ok, attachment_id} <- private_forward_attachment_id(attachment),
           false <- MapSet.member?(seen_ids, attachment_id),
           {:ok, _original_attachment} <-
             original_private_attachment(original_attachments, attachment_id),
           {:ok, verified_attachment} <-
             verify_private_forward_attachment(attachment, max_size) do
        {:cont, {:ok, [verified_attachment | verified], MapSet.put(seen_ids, attachment_id)}}
      else
        true -> {:halt, {:error, :duplicate_attachment}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, verified, _seen_ids} -> {:ok, Enum.reverse(verified)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp private_forward_attachment_id(%{"attachment_id" => id}) when is_binary(id) and id != "",
    do: {:ok, id}

  defp private_forward_attachment_id(%{"id" => id}) when is_binary(id) and id != "",
    do: {:ok, id}

  defp private_forward_attachment_id(_attachment), do: {:error, :invalid_attachment_id}

  defp original_private_attachment(original_attachments, attachment_id) do
    case Map.get(original_attachments, attachment_id) do
      attachment when is_map(attachment) ->
        if MailboxEncryption.attachment_encrypted?(attachment) do
          {:ok, attachment}
        else
          {:error, :attachment_not_private}
        end

      _ ->
        {:error, :attachment_not_found}
    end
  end

  defp verify_private_forward_attachment(attachment, max_size) when is_map(attachment) do
    filename = attachment["filename"]
    content_type = attachment["content_type"] || "application/octet-stream"
    data = attachment["data"]

    with true <- is_binary(filename) and filename != "",
         true <- is_binary(data) and data != "",
         :ok <- validate_attachment_type(filename, content_type),
         {:ok, decoded} <- Base.decode64(data),
         size <- byte_size(decoded),
         true <- size <= max_size do
      {:ok,
       %{
         "filename" => filename,
         "content_type" => content_type,
         "size" => size,
         "encoding" => "base64",
         "data" => Base.encode64(decoded)
       }}
    else
      false -> {:error, :invalid_attachment}
      :error -> {:error, :invalid_attachment_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp quote_message_body(body) do
    body |> String.split("\n") |> Enum.map_join("\n", &"> #{&1}")
  end

  defp format_date_for_quote(datetime) do
    case datetime do
      %DateTime{} -> Calendar.strftime(datetime, "%a, %b %d, %Y at %I:%M %p")
      _ -> ""
    end
  end

  defp get_page_title(params) do
    case Map.get(params, "mode") do
      "reply" -> "Reply to Message"
      "reply_all" -> "Reply All to Message"
      "forward" -> "Forward Message"
      _ -> "Compose Email"
    end
  end

  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<a\s+[^>]*href=["']([^"']+)["'][^>]*>([^<]+)<\/a>/i, "\\2 (\\1)")
    |> String.replace(
      ~r/<img\s+[^>]*src=["']([^"']+)["'][^>]*alt=["']([^"']*)["'][^>]*>/i,
      "[Image: \\2] (\\1)"
    )
    |> String.replace(
      ~r/<img\s+[^>]*alt=["']([^"']*)["'][^>]*src=["']([^"']+)["'][^>]*>/i,
      "[Image: \\1] (\\2)"
    )
    |> String.replace(~r/<img\s+[^>]*src=["']([^"']+)["'][^>]*>/i, "[Image] (\\1)")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p>/i, "\n\n")
    |> String.replace(~r/<\/div>/i, "\n")
    |> String.replace(~r/<\/h[1-6]>/i, "\n\n")
    |> String.replace(~r/<\/li>/i, "\n")
    |> String.replace(~r/<\/blockquote>/i, "\n")
    |> String.replace(~r/<li[^>]*>/i, "\n• ")
    |> String.replace(~r/<blockquote[^>]*>/i, "\n> ")
    |> String.replace(~r/<(strong|b)[^>]*>([^<]+)<\/(strong|b)>/i, "**\\2**")
    |> String.replace(~r/<(em|i)[^>]*>([^<]+)<\/(em|i)>/i, "*\\2*")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s+\n/, "\n\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp markdown_to_html(markdown) do
    markdown
    |> MDEx.to_html!(render: [hardbreaks: true])
    |> Elektrine.Email.Sanitizer.sanitize_html_content()
  end

  defp html_body_for_format(_body, "plaintext"), do: nil

  defp html_body_for_format(body, _format), do: markdown_to_html(body || "")

  defp body_format(params, fallback \\ "markdown")

  defp body_format(%{} = params, fallback) do
    case Map.get(params, "body_format") || Map.get(params, :body_format) || fallback do
      value when value in ["plaintext", "plain_text", "plain", :plaintext, :plain_text, :plain] ->
        "plaintext"

      _ ->
        "markdown"
    end
  end

  defp body_format(_params, fallback), do: body_format(%{"body_format" => fallback})

  defp put_body_format(params, fallback) when is_map(params) do
    Map.put(params, "body_format", body_format(params, fallback))
  end

  defp blank_reply?(mode, email_params) when mode in ["reply", "reply_all"] do
    email_params
    |> Map.get("new_message", "")
    |> meaningful_body?()
    |> Kernel.not()
  end

  defp blank_reply?(_mode, _email_params), do: false

  defp draft_body(email_params, mode) when mode in ["reply", "reply_all", "forward"] do
    email_params
    |> Map.get("new_message", email_params["body"] || "")
    |> normalize_message_body()
  end

  defp draft_body(email_params, _mode), do: email_params["body"] || ""

  defp put_template_body(form, mode, body) when mode in ["reply", "reply_all", "forward"] do
    Map.put(form, "new_message", body)
  end

  defp put_template_body(form, _mode, body) do
    Map.put(form, "body", body)
  end

  defp combine_reply_text(new_message, quoted_body) do
    [normalize_message_body(new_message), normalize_message_body(quoted_body)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp normalize_message_body(body) when is_binary(body) do
    body
    |> String.replace(<<0xC2, 0xA0>>, " ")
    |> String.replace(<<0xE2, 0x80, 0x8B>>, "")
    |> String.replace(<<0xE2, 0x80, 0x8C>>, "")
    |> String.replace(<<0xE2, 0x80, 0x8D>>, "")
    |> String.replace(<<0xEF, 0xBB, 0xBF>>, "")
    |> String.trim()
  end

  defp normalize_message_body(_), do: ""

  defp meaningful_body?(body), do: normalize_message_body(body) != ""

  defp extract_clean_email(nil) do
    nil
  end

  defp extract_clean_email(email) when is_binary(email) do
    first_email = email |> String.split(",") |> List.first() |> String.trim()

    cond do
      Regex.match?(~r/<([^@>]+@[^>]+)>/, first_email) ->
        [_, clean] = Regex.run(~r/<([^@>]+@[^>]+)>/, first_email)
        String.trim(clean)

      Regex.match?(~r/([^\s<>]+@[^\s<>]+)/, first_email) ->
        [_, clean] = Regex.run(~r/([^\s<>]+@[^\s<>]+)/, first_email)
        String.trim(clean)

      Regex.match?(~r/^[^\s]+@[^\s]+$/, first_email) ->
        String.trim(first_email)

      true ->
        String.trim(first_email)
    end
  end

  defp build_reply_recipients(message, _mailbox, reply_type) do
    original_sender = extract_clean_email(message.from)

    to_recipients =
      if Elektrine.Strings.present?(message.to) do
        message.to
        |> String.split(~r/[,;]\s*/)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&extract_clean_email/1)
        |> Enum.reject(&(&1 == ""))
      else
        []
      end

    cc_recipients =
      if Elektrine.Strings.present?(message.cc) do
        message.cc
        |> String.split(~r/[,;]\s*/)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&extract_clean_email/1)
        |> Enum.reject(&(&1 == ""))
      else
        []
      end

    case reply_type do
      :sender_only ->
        if message.status == "sent" do
          reply_to = to_recipients |> Enum.uniq() |> Enum.join(", ")
          {reply_to, ""}
        else
          {original_sender, ""}
        end

      :all_recipients ->
        if message.status == "sent" do
          reply_to = to_recipients |> Enum.uniq() |> Enum.join(", ")
          reply_cc = cc_recipients |> Enum.uniq() |> Enum.join(", ")
          {reply_to, reply_cc}
        else
          reply_to_list = [original_sender | to_recipients]
          reply_to = reply_to_list |> Enum.uniq() |> Enum.join(", ")
          reply_cc = cc_recipients |> Enum.uniq() |> Enum.join(", ")
          {reply_to, reply_cc}
        end
    end
  end

  defp maybe_put_reply_references(attrs, references) do
    if Elektrine.Strings.present?(references) do
      Map.put(attrs, :references, references)
    else
      attrs
    end
  end

  defp build_reply_references(original_message, reply_to_id) do
    original_references =
      original_message.references
      |> parse_reference_ids()

    parent_message_id =
      if original_message.metadata &&
           Map.has_key?(original_message.metadata, "original_message_id") do
        original_message.metadata["original_message_id"]
      else
        original_message.message_id
      end

    [original_references, [parent_message_id], [reply_to_id]]
    |> List.flatten()
    |> Enum.map(&normalize_message_id_header/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      refs -> Enum.join(refs, " ")
    end
  end

  defp parse_reference_ids(nil), do: []
  defp parse_reference_ids(""), do: []

  defp parse_reference_ids(value) when is_binary(value) do
    value
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&normalize_message_id_header/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_reference_ids(value) when is_list(value) do
    value
    |> Enum.map(&normalize_message_id_header/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_reference_ids(_), do: []

  defp normalize_message_id_header(nil), do: nil
  defp normalize_message_id_header(""), do: nil

  defp normalize_message_id_header(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/^<|>$/, "")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_message_id_header(value), do: to_string(value) |> normalize_message_id_header()

  defp get_available_from_addresses(_mailbox, user) do
    base_addresses = Elektrine.Domains.email_addresses_for_user(user)

    user_aliases =
      Email.list_aliases(user.id) |> Enum.filter(& &1.enabled) |> Enum.map(& &1.alias_email)

    (base_addresses ++ user_aliases) |> Enum.uniq() |> Enum.sort()
  end

  defp determine_from_address(nil, mailbox) do
    user = Elektrine.Repo.get(Elektrine.Accounts.User, mailbox.user_id)

    preferred_domain =
      Map.get(user, :preferred_email_domain, Elektrine.Domains.default_user_handle_domain())

    mailbox_address_for_domain(user, mailbox.email, preferred_domain) || mailbox.email
  end

  defp determine_from_address(original_message, mailbox) do
    to_address = original_message.to || ""
    recipient_email = extract_email_address(to_address)
    user_aliases = Email.list_aliases(mailbox.user_id)

    matching_alias =
      Enum.find(user_aliases, fn alias_record -> alias_record.alias_email == recipient_email end)

    if matching_alias != nil do
      matching_alias.alias_email
    else
      case extract_domain(recipient_email) do
        domain when is_binary(domain) ->
          user = Elektrine.Repo.get(Elektrine.Accounts.User, mailbox.user_id)

          if domain in Elektrine.Domains.available_email_domains_for_user(user) do
            mailbox_address_for_domain(user, mailbox.email, domain) || mailbox.email
          else
            mailbox.email
          end

        _ ->
          mailbox.email
      end
    end
  end

  defp extract_email_address(address_string) when is_binary(address_string) do
    case Regex.run(~r/<([^>]+)>/, address_string) do
      [_, email] -> String.downcase(String.trim(email))
      nil -> String.downcase(String.trim(address_string))
    end
  end

  defp extract_email_address(_) do
    ""
  end

  defp extract_domain(address) when is_binary(address) do
    case String.split(String.downcase(String.trim(address)), "@", parts: 2) do
      [_local, domain] -> domain
      _ -> nil
    end
  end

  defp extract_domain(_), do: nil

  defp mailbox_address_for_domain(user, _base_email, domain)
       when is_binary(domain) and not is_nil(user) do
    downcased_domain = String.downcase(domain)

    Elektrine.Domains.email_addresses_for_user(user)
    |> Enum.find(fn address ->
      String.ends_with?(String.downcase(address), "@#{downcased_domain}")
    end)
  end

  defp mailbox_address_for_domain(_, _, _), do: nil

  defp validate_attachments(socket) do
    user = socket.assigns.current_user
    entries = socket.assigns.uploads.attachments.entries

    case check_attachment_rate_limit(user.id) do
      {:ok, _count} ->
        Enum.reduce(entries, socket, fn entry, acc_socket ->
          case validate_file_content(entry) do
            :ok ->
              acc_socket

            {:error, reason} ->
              cancel_upload(acc_socket, :attachments, entry.ref)
              |> put_flash(:error, "File #{entry.client_name}: #{reason}")
          end
        end)

      {:error, :rate_limit_exceeded} ->
        socket |> put_flash(:error, "Attachment upload limit exceeded (max 20 files per hour)")
    end
  end

  defp check_attachment_rate_limit(user_id) do
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second)

    attachment_count =
      Elektrine.Repo.one(
        from(m in Elektrine.Email.Message,
          join: mb in Elektrine.Email.Mailbox,
          on: m.mailbox_id == mb.id,
          where:
            mb.user_id == ^user_id and m.status == "sent" and m.inserted_at >= ^one_hour_ago and
              m.has_attachments == true,
          select: count(m.id)
        )
      )

    if attachment_count >= 20 do
      {:error, :rate_limit_exceeded}
    else
      {:ok, attachment_count}
    end
  end

  defp attachment_rate_limited?(user_id) do
    match?({:error, :rate_limit_exceeded}, check_attachment_rate_limit(user_id))
  end

  defp any_attachment_too_large?(attachments, user) do
    max_size = email_attachment_limit(user)

    Enum.any?(attachments, fn attachment ->
      attachment_size(attachment) > max_size
    end)
  end

  defp attachment_size(attachment) when is_map(attachment) do
    case Map.get(attachment, "size") || Map.get(attachment, :size) do
      size when is_integer(size) and size >= 0 ->
        size

      size when is_binary(size) ->
        case Integer.parse(size) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp attachment_size(_attachment), do: 0

  defp email_attachment_limit(%{is_admin: true}), do: Constants.max_email_attachment_size_admin()
  defp email_attachment_limit(_user), do: Constants.max_email_attachment_size()

  defp build_rate_limit_error_message(user_id) do
    restriction = RateLimiter.get_restriction_status(user_id)

    if restriction.restricted do
      "Email sending is temporarily restricted due to repeated rate limit violations. Verify your recovery email or contact support to restore sending access."
    else
      status = RateLimiter.get_status(user_id)

      cond do
        status.attempts[60].remaining == 0 ->
          "You have reached your per-minute limit of #{status.attempts[60].limit} emails. Please wait a minute and try again."

        status.attempts[3600].remaining == 0 ->
          "You have reached your hourly limit of #{status.attempts[3600].limit} emails. Please try again later."

        true ->
          "Email rate limit exceeded. Please try again later."
      end
    end
  end

  defp validate_file_content(entry) do
    validate_attachment_type(entry.client_name, entry.client_type)
  end

  defp validate_attachment_type(filename, content_type) when is_binary(filename) do
    ext = Path.extname(filename) |> String.downcase()
    content_type = normalize_attachment_content_type(content_type)

    case Map.get(@allowed_attachment_types, ext) do
      nil ->
        {:error, "File type not allowed"}

      allowed_types ->
        if content_type in allowed_types or content_type in @generic_attachment_content_types do
          :ok
        else
          {:error, "File type mismatch (extension: #{ext}, type: #{content_type})"}
        end
    end
  end

  defp validate_attachment_type(_filename, _content_type), do: {:error, "File type not allowed"}

  defp normalize_attachment_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_attachment_content_type(_content_type), do: ""

  defp error_to_string(:too_large) do
    gettext("File is too large (max 10MB)")
  end

  defp error_to_string(:too_many_files) do
    gettext("Too many files (max 5)")
  end

  defp error_to_string(:not_accepted) do
    gettext("File type not accepted")
  end

  defp error_to_string(error) do
    UserErrorHelpers.reason_message(error, gettext("Upload failed. Please try again."))
  end

  defp parse_email_tags(email_string) when is_binary(email_string) do
    email_string
    |> String.split(~r/[,;]\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != "" && valid_email?(&1)))
  end

  defp parse_email_tags(_) do
    []
  end

  defp assign_encryption_state(socket, mode_override \\ nil) do
    mode = mode_override || socket.assigns[:encryption_mode] || "auto"

    recipients =
      (socket.assigns.to_tags || []) ++
        (socket.assigns.cc_tags || []) ++ (socket.assigns.bcc_tags || [])

    status =
      recipients
      |> PGP.recipient_encryption_status(socket.assigns.current_user.id, fetch_remote: false)
      |> Map.put(:server_ready?, PGP.gpg_available?())

    socket
    |> assign(:encryption_mode, mode)
    |> assign(:encryption_status, status)
  end

  defp missing_pgp_keys_message([]) do
    "Encryption is required, but no recipient public keys are available."
  end

  defp missing_pgp_keys_message(missing_recipients) do
    displayed =
      missing_recipients
      |> Enum.take(3)
      |> Enum.join(", ")

    suffix =
      if length(missing_recipients) > 3 do
        ", and #{length(missing_recipients) - 3} more"
      else
        ""
      end

    "Encryption is required, but no public key was found for #{displayed}#{suffix}."
  end

  defp valid_email?(email) when is_binary(email) do
    String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end

  defp valid_email?(_) do
    false
  end

  defp count_words(text) when is_binary(text) do
    text |> String.trim() |> String.split(~r/\s+/) |> Enum.reject(&(&1 == "")) |> length()
  end

  defp count_words(_) do
    0
  end

  defp append_signature(body, user) do
    if user && Elektrine.Strings.present?(user.email_signature) do
      body <> "\n\n-- \n" <> user.email_signature
    else
      body
    end
  end

  ## Compose UI components

  # Write/Preview/Split tabs plus the markdown formatting toolbar. The tab
  # attribute, toolbar id, and textarea target differ between the compose and
  # reply editors because separate JS (markdown_toolbar.js and
  # ReplyMarkdownEditor) drives each by id.
  attr :tab_attr, :string, required: true
  attr :toolbar_id, :string, required: true
  attr :target, :string, required: true

  defp editor_toolbar(assigns) do
    ~H"""
    <div class="tabs tabs-boxed bg-base-200">
      <button type="button" class="tab tab-active" {%{@tab_attr => "write"}}>
        <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> {gettext("Write")}
      </button>
      <button type="button" class="tab" {%{@tab_attr => "preview"}}>
        <.icon name="hero-eye" class="w-4 h-4 mr-1" /> {gettext("Preview")}
      </button>
      <button type="button" class="tab" {%{@tab_attr => "split"}}>
        <.icon name="hero-view-columns" class="w-4 h-4 mr-1" /> {gettext("Split")}
      </button>
    </div>
    <div class="flex flex-wrap items-center gap-1 p-2 bg-base-200 rounded-t-lg" id={@toolbar_id}>
      <div class="flex items-center gap-1">
        <button
          type="button"
          class="btn btn-sm btn-ghost hover:bg-secondary/20 tooltip"
          data-markdown-format="bold"
          data-target={@target}
          data-tip={gettext("Bold (Ctrl+B)")}
        >
          <strong class="text-sm">B</strong>
        </button>
        <button
          type="button"
          class="btn btn-sm btn-ghost hover:bg-secondary/20 tooltip"
          data-markdown-format="italic"
          data-target={@target}
          data-tip={gettext("Italic (Ctrl+I)")}
        >
          <em class="text-sm">I</em>
        </button>
        <button
          type="button"
          class="btn btn-sm btn-ghost hover:bg-secondary/20 tooltip"
          data-markdown-format="code"
          data-target={@target}
          data-tip={gettext("Code")}
        >
          <.icon name="hero-code-bracket" class="w-4 h-4" />
        </button>
      </div>

      <div class="divider divider-horizontal h-6 mx-1"></div>

      <div class="dropdown dropdown-hover">
        <button type="button" tabindex="0" class="btn btn-sm btn-ghost hover:bg-secondary/20 gap-1">
          <span class="text-sm font-bold">H</span>
          <.icon name="hero-chevron-down" class="w-3 h-3" />
        </button>
        <ul tabindex="0" class="dropdown-content z-50 menu p-2 rounded-box w-32">
          <li :for={level <- ["h1", "h2", "h3"]}>
            <button type="button" data-markdown-format={level} data-target={@target}>
              {String.upcase(level)}
            </button>
          </li>
        </ul>
      </div>

      <div class="flex items-center gap-1">
        <button
          type="button"
          class="btn btn-sm btn-ghost hover:bg-secondary/20 tooltip"
          data-markdown-format="list-bullet"
          data-target={@target}
          data-tip={gettext("Bullet list")}
        >
          <.icon name="hero-list-bullet" class="w-4 h-4" />
        </button>
        <button
          type="button"
          class="btn btn-sm btn-ghost hover:bg-secondary/20 tooltip"
          data-markdown-format="list-number"
          data-target={@target}
          data-tip={gettext("Numbered list")}
        >
          <span class="text-sm">1.</span>
        </button>
        <button
          type="button"
          class="btn btn-sm btn-ghost hover:bg-secondary/20 tooltip"
          data-markdown-format="link"
          data-target={@target}
          data-tip={gettext("Insert link")}
        >
          <.icon name="hero-link" class="w-4 h-4" />
        </button>
      </div>

      <div class="divider divider-horizontal h-6 mx-1"></div>

      <div class="flex items-center gap-1">
        <button
          type="button"
          class="btn btn-sm btn-ghost hover:bg-secondary/20 tooltip"
          data-markdown-format="quote"
          data-target={@target}
          data-tip={gettext("Quote")}
        >
          <.icon name="hero-chat-bubble-bottom-center-text" class="w-4 h-4" />
        </button>
        <button
          type="button"
          class="btn btn-sm btn-ghost hover:bg-secondary/20 tooltip"
          data-markdown-format="code-block"
          data-target={@target}
          data-tip={gettext("Code block")}
        >
          <span class="text-xs font-medium">[/]</span>
        </button>
      </div>
    </div>
    """
  end

  # Tag-style recipient input with autocomplete. Ids follow the
  # "#{field}-tag-input" / "#{field}-suggestions-dropdown" convention that
  # TagInputHook and SuggestionDropdown expect.
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :required, :boolean, default: false
  attr :tags, :list, required: true
  attr :input_value, :string, default: ""
  attr :error, :any, default: nil
  attr :show_suggestions, :boolean, default: false
  attr :suggestions, :list, default: []

  defp recipient_field(assigns) do
    ~H"""
    <div class="relative">
      <label class="label">
        <span class="font-semibold">
          {@label} <span :if={@required} class="text-error">*</span>
        </span>
      </label>
      <div class={"input input-bordered w-full h-auto min-h-10 flex flex-wrap gap-1.5 p-2 items-center #{if @error, do: "input-error"}"}>
        <span
          :for={email <- @tags}
          class="inline-flex items-center gap-1 px-2 py-0.5 bg-base-300 text-base-content rounded text-sm"
        >
          <span>{email}</span>
          <button
            type="button"
            phx-click="remove_tag"
            phx-value-field={@field}
            phx-value-email={email}
            aria-label={gettext("Remove %{email}", email: email)}
            class="-my-1 -mr-1 flex h-6 w-6 items-center justify-center rounded-full text-sm leading-none opacity-60 transition-colors hover:bg-error/30 hover:text-error hover:opacity-100"
          >
            &times;
          </button>
        </span>

        <input
          type="text"
          value={@input_value}
          phx-hook="TagInputHook"
          data-field={@field}
          phx-blur="tag_input_blur"
          phx-keydown="tag_input_keydown"
          phx-value-field={@field}
          id={"#{@field}-tag-input"}
          placeholder={gettext("Add email...")}
          autocomplete="off"
          data-lpignore="true"
          data-1p-ignore="true"
          class={"flex-1 min-w-[7rem] sm:min-w-[150px] outline-none bg-transparent border-none focus:outline-none focus:ring-0 text-sm #{if @error, do: "text-error"}"}
        />
      </div>

      <p :if={@error} class="text-error text-xs mt-1">{gettext("Invalid email address")}</p>

      <div
        :if={@show_suggestions}
        class="absolute z-50 mt-1 w-full rounded-lg border border-base-300 bg-base-200/95 text-base-content shadow-xl backdrop-blur-sm max-h-60 overflow-y-auto"
        phx-hook="SuggestionDropdown"
        id={"#{@field}-suggestions-dropdown"}
      >
        <div
          :for={suggestion <- @suggestions}
          data-suggestion-email={suggestion.email}
          data-suggestion-field={@field}
          class="w-full text-left px-4 py-2 hover:bg-secondary/10 transition-colors flex items-center gap-3 cursor-pointer"
        >
          <div class="w-8 h-8 bg-secondary/20 rounded-full flex items-center justify-center text-secondary font-semibold">
            {String.first(String.upcase(suggestion.name || suggestion.email))}
          </div>

          <div class="flex-1 min-w-0">
            <div class="font-medium text-sm truncate">
              {suggestion.name || String.split(suggestion.email, "@") |> List.first()}
            </div>

            <div class="text-xs opacity-70 truncate">{suggestion.email}</div>
          </div>

          <div :if={suggestion.source == "contact"} class="badge badge-secondary badge-xs">
            Contact
          </div>
          <div :if={suggestion.source != "contact"} class="badge badge-ghost badge-xs">
            Recent
          </div>
        </div>
      </div>
    </div>
    """
  end
end
