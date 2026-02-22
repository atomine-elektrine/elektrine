defmodule ElektrineWeb.EmailLive.Compose do
  use ElektrineWeb, :live_view
  import ElektrineWeb.EmailLive.EmailHelpers
  import ElektrineWeb.Components.Platform.ElektrineNav
  import Ecto.Query
  alias Elektrine.Constants
  alias Elektrine.Email
  alias Elektrine.Email.AttachmentStorage
  alias Elektrine.Email.RateLimiter
  alias Elektrine.Email.Sender
  require Logger
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
          case Email.get_user_message(String.to_integer(id), user.id) do
            {:ok, message} -> message
            {:error, _} -> nil
          end
      end

    available_from_addresses = get_available_from_addresses(mailbox, fresh_user)
    from_address = determine_from_address(original_message, mailbox)
    rate_limit_status = RateLimiter.get_rate_limit_status(user.id)
    storage_info = Elektrine.Accounts.Storage.get_storage_info(user.id)
    return_to = Map.get(params, "return_to", "inbox")
    return_filter = Map.get(params, "filter", "inbox")
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

    {:ok,
     socket
     |> assign(:page_title, page_title)
     |> assign(:templates, templates)
     |> assign(:mailbox, mailbox)
     |> assign(:from_address, from_address)
     |> assign(:available_from_addresses, available_from_addresses)
     |> assign(:unread_count, unread_count)
     |> assign(:storage_info, storage_info)
     |> assign(:mode, Map.get(params, "mode", "compose"))
     |> assign(:original_message_id, Map.get(params, "message_id"))
     |> assign(:original_message, original_message)
     |> assign(:rate_limit_status, rate_limit_status)
     |> assign(:return_to, return_to)
     |> assign(:return_filter, return_filter)
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
     |> assign(:draft_id, form_data["draft_id"])
     |> assign(:draft_status, nil)
     |> assign(:sending, false)
     |> allow_upload(:attachments,
       accept: ~w(.jpg .jpeg .png .gif .pdf .doc .docx .xls .xlsx .txt),
       max_entries: 5,
       max_file_size: email_attachment_limit,
       auto_upload: true
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page_title = get_page_title(params)

    original_message =
      case Map.get(params, "message_id") do
        nil ->
          nil

        id ->
          case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
            {:ok, message} -> message
            {:error, _} -> nil
          end
      end

    from_address = determine_from_address(original_message, socket.assigns.mailbox)
    return_to = Map.get(params, "return_to", socket.assigns.return_to)
    return_filter = Map.get(params, "filter", socket.assigns.return_filter)

    socket =
      if !socket.assigns[:form] || Map.get(params, "mode") != socket.assigns[:mode] do
        form_data = build_form_data(params, socket.assigns.mailbox)
        to_tags = parse_email_tags(form_data["to"] || "")
        cc_tags = parse_email_tags(form_data["cc"] || "")
        bcc_tags = parse_email_tags(form_data["bcc"] || "")

        socket
        |> assign(:form, to_form(form_data))
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
     |> assign(:return_to, return_to)
     |> assign(:return_filter, return_filter)}
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
  def handle_event("clear_form", _params, socket) do
    {:noreply,
     socket
     |> assign(
       :form,
       to_form(%{"to" => "", "cc" => "", "bcc" => "", "subject" => "", "body" => ""})
     )
     |> notify_info("Form cleared")}
  end

  @impl true
  def handle_event("apply_template", %{"template_id" => ""}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("apply_template", %{"template_id" => template_id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_template(String.to_integer(template_id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Template not found")}

      template ->
        current_form = socket.assigns.form.params || %{}

        updated_form =
          current_form
          |> Map.put("subject", template.subject || current_form["subject"] || "")
          |> Map.put("body", template.body || "")

        {:noreply,
         socket
         |> assign(:form, to_form(updated_form))
         |> assign(:body_char_count, String.length(template.body || ""))
         |> assign(:body_word_count, count_words(template.body || ""))
         |> put_flash(:info, "Template \"#{template.name}\" applied")}
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
    body = email_params["body"] || email_params["new_message"] || ""
    word_count = count_words(body)

    {:noreply,
     socket |> assign(:form, to_form(email_params)) |> assign(:body_word_count, word_count)}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    socket = validate_attachments(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_and_autosave", %{"email" => email_params}, socket) do
    socket = validate_attachments(socket)
    body = email_params["body"] || email_params["new_message"] || ""
    word_count = count_words(body)

    socket =
      socket |> assign(:form, to_form(email_params)) |> assign(:body_word_count, word_count)

    has_content =
      String.trim(email_params["subject"] || "") != "" ||
        String.trim(email_params["body"] || "") != ""

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

    {:noreply, socket}
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

    {:noreply, socket}
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
         |> assign(showing_key, false)}
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
      {:noreply, socket}
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

    {:noreply, socket}
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
    socket = assign(socket, :sending, true)
    user = socket.assigns.current_user
    _mailbox = socket.assigns.mailbox
    mode = socket.assigns.mode
    original_message = Map.get(socket.assigns, :original_message)

    {text_body, html_body} =
      if mode in ["reply", "reply_all", "forward"] && email_params["new_message"] do
        new_message = email_params["new_message"]
        combined_text = email_params["body"]

        combined_html =
          if original_message && original_message.html_body &&
               String.trim(original_message.html_body) != "" do
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

        {combined_text, combined_html}
      else
        text = email_params["body"]
        text_with_signature = append_signature(text, socket.assigns.current_user)
        html = markdown_to_html(text_with_signature)
        {text_with_signature, html}
      end

    email_attrs = %{
      from: socket.assigns.from_address,
      to: Enum.join(socket.assigns.to_tags, ", "),
      cc: Enum.join(socket.assigns.cc_tags, ", "),
      bcc: Enum.join(socket.assigns.bcc_tags, ", "),
      subject: email_params["subject"],
      text_body: text_body,
      html_body: html_body
    }

    temp_message_id = "temp_#{System.system_time(:millisecond)}"
    mailbox_id = socket.assigns.mailbox.id

    uploaded_attachments =
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

    {all_db_attachments, all_email_attachments} =
      if mode == "forward" && original_message && original_message.attachments do
        forwarded_with_data =
          original_message.attachments
          |> Map.values()
          |> Enum.map(fn att ->
            att_with_data =
              if att["storage_type"] == "s3" do
                case AttachmentStorage.download_attachment(att) do
                  {:ok, content} ->
                    Map.put(att, "data", Base.encode64(content))

                  {:error, _} ->
                    Logger.warning("Failed to download forwarded attachment from S3")
                    att
                end
              else
                att
              end

            {att, att_with_data}
          end)

        {fwd_db, fwd_email} = Enum.unzip(forwarded_with_data)
        {db_attachments ++ fwd_db, email_attachments ++ fwd_email}
      else
        {db_attachments, email_attachments}
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

        Map.put(email_attrs, :in_reply_to, reply_to_id)
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

    case Sender.send_email(user.id, email_attrs, db_attachments_map) do
      {:ok, _message} ->
        Elektrine.Accounts.Storage.update_user_storage(user.id)

        if draft_id = socket.assigns[:draft_id] do
          Email.delete_draft(draft_id, socket.assigns.mailbox.id)
        end

        updated_status = RateLimiter.get_rate_limit_status(user.id)
        return_url = get_return_url(socket.assigns)

        {:noreply,
         socket
         |> assign(:rate_limit_status, updated_status)
         |> notify_info("Email sent successfully!")
         |> push_navigate(to: return_url)}

      {:error, :rate_limit_exceeded} ->
        daily_limit = Elektrine.Email.RateLimiter.daily_limit()

        {:noreply,
         socket
         |> assign(:sending, false)
         |> notify_error(
           "You have reached your daily limit of #{daily_limit} emails. Please try again tomorrow."
         )
         |> assign(:form, to_form(email_params))}

      {:error, :storage_limit_exceeded} ->
        {:noreply,
         socket
         |> assign(:sending, false)
         |> notify_error(
           "Cannot send email: your mailbox storage limit (5MB) has been exceeded. Please delete some emails first."
         )
         |> assign(:form, to_form(email_params))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:sending, false)
         |> notify_error("Failed to send email: #{inspect(reason)}")
         |> assign(:form, to_form(email_params))}
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
      text_body: email_params["body"] || "",
      html_body: markdown_to_html(email_params["body"] || ""),
      status: "draft"
    }

    case Email.save_draft(draft_attrs, draft_id) do
      {:ok, saved_draft} ->
        {:noreply, socket |> assign(:draft_id, saved_draft.id) |> notify_info("Draft saved")}

      {:error, _reason} ->
        {:noreply, socket |> notify_error("Failed to save draft")}
    end
  end

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
          socket |> assign(error_key, false)

        valid_email?(email) && email not in current_tags ->
          socket
          |> assign(tags_key, current_tags ++ [email])
          |> assign(input_key, "")
          |> assign(error_key, false)

        valid_email?(email) ->
          socket |> assign(input_key, "") |> assign(error_key, false)

        true ->
          socket |> assign(input_key, "") |> assign(error_key, false)
      end
    else
      socket
    end
  end

  @impl true
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

    draft_attrs = %{
      mailbox_id: mailbox.id,
      from: socket.assigns.from_address,
      to: Enum.join(socket.assigns.to_tags, ", "),
      cc: Enum.join(socket.assigns.cc_tags, ", "),
      bcc: Enum.join(socket.assigns.bcc_tags, ", "),
      subject: email_params["subject"] || "",
      text_body: email_params["body"] || "",
      html_body: markdown_to_html(email_params["body"] || ""),
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
          "body" => Map.get(params, "body", "")
        }
    end
  end

  defp build_draft_data(draft_id, mailbox) do
    draft_id_int =
      if is_binary(draft_id) do
        String.to_integer(draft_id)
      else
        draft_id
      end

    case Email.get_draft(draft_id_int, mailbox.id) do
      nil ->
        Logger.warning("Draft not found: #{draft_id}")
        %{"to" => "", "cc" => "", "bcc" => "", "subject" => "", "body" => "", "draft_id" => nil}

      draft ->
        %{
          "to" => draft.to || "",
          "cc" => draft.cc || "",
          "bcc" => draft.bcc || "",
          "subject" => draft.subject || "",
          "body" => draft.text_body || "",
          "draft_id" => draft.id
        }
    end
  end

  defp build_reply_data(message_id, mailbox, reply_type) do
    message_id_int =
      if is_binary(message_id) do
        String.to_integer(message_id)
      else
        message_id
      end

    case Email.get_user_message(message_id_int, mailbox.user_id) do
      {:error, _} ->
        Logger.warning("Message not found or access denied for reply: #{message_id}")
        %{"to" => "", "cc" => "", "bcc" => "", "subject" => "", "body" => ""}

      {:ok, message} ->
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
          "new_message" => ""
        }
    end
  end

  defp build_forward_data(message_id, mailbox) do
    message_id_int =
      if is_binary(message_id) do
        String.to_integer(message_id)
      else
        message_id
      end

    case Email.get_user_message(message_id_int, mailbox.user_id) do
      {:error, _} ->
        %{"to" => "", "cc" => "", "bcc" => "", "subject" => "", "body" => ""}

      {:ok, message} ->
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
        %{"to" => "", "cc" => "", "bcc" => "", "subject" => subject, "body" => forwarded_body}
    end
  end

  defp format_quoted_reply(message) do
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

  defp format_forwarded_message(message) do
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
    |> String.replace(~r/^### (.*)$/m, "<h3>\\1</h3>")
    |> String.replace(~r/^## (.*)$/m, "<h2>\\1</h2>")
    |> String.replace(~r/^# (.*)$/m, "<h1>\\1</h1>")
    |> String.replace(~r/\*\*(.*?)\*\*/s, "<strong>\\1</strong>")
    |> String.replace(~r/\*(.*?)\*/s, "<em>\\1</em>")
    |> String.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, "<a href=\"\\2\">\\1</a>")
    |> String.replace(~r/^- (.*)$/m, "<li>\\1</li>")
    |> String.replace(~r/^> (.*)$/m, "<blockquote>\\1</blockquote>")
    |> String.replace("\n", "<br>")
  end

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
      if message.to && String.trim(message.to) != "" do
        message.to
        |> String.split(~r/[,;]\s*/)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&extract_clean_email/1)
        |> Enum.reject(&(&1 == ""))
      else
        []
      end

    cc_recipients =
      if message.cc && String.trim(message.cc) != "" do
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

  defp get_available_from_addresses(mailbox, user) do
    base_email = mailbox.email

    base_addresses =
      case base_email do
        nil ->
          []

        email when is_binary(email) ->
          if String.ends_with?(email, "@elektrine.com") do
            z_org_email = String.replace(email, "@elektrine.com", "@z.org")
            [email, z_org_email]
          else
            [email]
          end
      end

    user_aliases =
      Email.list_aliases(user.id) |> Enum.filter(& &1.enabled) |> Enum.map(& &1.alias_email)

    (base_addresses ++ user_aliases) |> Enum.uniq() |> Enum.sort()
  end

  defp determine_from_address(nil, mailbox) do
    user = Elektrine.Repo.get(Elektrine.Accounts.User, mailbox.user_id)
    preferred_domain = Map.get(user, :preferred_email_domain, "z.org")

    if preferred_domain == "z.org" do
      String.replace(mailbox.email, "@elektrine.com", "@z.org")
    else
      mailbox.email
    end
  end

  defp determine_from_address(original_message, mailbox) do
    to_address = original_message.to || ""
    recipient_email = extract_email_address(to_address)
    user_aliases = Email.list_aliases(mailbox.user_id)

    matching_alias =
      Enum.find(user_aliases, fn alias_record -> alias_record.alias_email == recipient_email end)

    cond do
      matching_alias != nil ->
        matching_alias.alias_email

      String.contains?(to_address, "@z.org") ->
        String.replace(mailbox.email, "@elektrine.com", "@z.org")

      String.contains?(to_address, "@elektrine.com") ->
        mailbox.email

      true ->
        mailbox.email
    end
  end

  defp extract_email_address(nil) do
    ""
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

  defp get_return_url(assigns) do
    return_to = assigns[:return_to] || "inbox"
    return_filter = assigns[:return_filter] || "inbox"

    case return_to do
      "sent" -> ~p"/email?tab=sent"
      "spam" -> ~p"/email?tab=spam"
      "archive" -> ~p"/email?tab=archive"
      "search" -> ~p"/email?tab=search"
      "inbox" when return_filter != "inbox" -> ~p"/email?tab=inbox&filter=#{return_filter}"
      _ -> ~p"/email?tab=inbox"
    end
  end

  defp get_back_button_text(assigns) do
    return_to = assigns[:return_to] || "inbox"
    return_filter = assigns[:return_filter] || "inbox"

    case return_to do
      "sent" ->
        gettext("Back to Sent")

      "spam" ->
        gettext("Back to Spam")

      "archive" ->
        gettext("Back to Archive")

      "search" ->
        gettext("Back to Search")

      "inbox" ->
        case return_filter do
          "bulk_mail" -> gettext("Back to Bulk Mail")
          "paper_trail" -> gettext("Back to Paper Trail")
          "the_pile" -> gettext("Back to The Pile")
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

  defp validate_file_content(entry) do
    ext = Path.extname(entry.client_name) |> String.downcase()

    valid_types = %{
      ".jpg" => ["image/jpeg"],
      ".jpeg" => ["image/jpeg"],
      ".png" => ["image/png"],
      ".gif" => ["image/gif"],
      ".pdf" => ["application/pdf"],
      ".doc" => ["application/msword"],
      ".docx" => ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
      ".xls" => ["application/vnd.ms-excel"],
      ".xlsx" => ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
      ".txt" => ["text/plain"]
    }

    case Map.get(valid_types, ext) do
      nil ->
        {:error, "File type not allowed"}

      allowed_types ->
        if entry.client_type in allowed_types do
          :ok
        else
          {:error, "File type mismatch (extension: #{ext}, type: #{entry.client_type})"}
        end
    end
  end

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
    gettext("Upload error: %{error}", error: inspect(error))
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
    if user && user.email_signature && String.trim(user.email_signature) != "" do
      body <> "\n\n-- \n" <> user.email_signature
    else
      body
    end
  end
end
