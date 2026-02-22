defmodule ElektrineWeb.EmailLive.Settings do
  use ElektrineWeb, :live_view
  import ElektrineWeb.EmailLive.EmailHelpers
  import ElektrineWeb.Components.Platform.ElektrineNav

  alias Elektrine.Email

  alias Elektrine.Email.{
    BlockedSender,
    SafeSender,
    Filter,
    Template,
    Folder,
    Label,
    Alias,
    Aliases
  }

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    if is_nil(user) do
      {:ok,
       socket
       |> put_flash(:error, "You must be logged in to access email settings")
       |> redirect(to: ~p"/login")}
    else
      mount_authenticated(user, session, socket)
    end
  end

  defp mount_authenticated(user, session, socket) do
    mailbox = get_or_create_mailbox(user)

    # Get fresh user data to ensure latest locale preference
    fresh_user = Elektrine.Accounts.get_user!(user.id)

    # Set locale for this LiveView process
    locale = fresh_user.locale || session["locale"] || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    unread_count = Email.unread_count(mailbox.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "mailbox:#{mailbox.id}")
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "email:exports:#{user.id}")
    end

    # Get storage info
    storage_info = Elektrine.Accounts.Storage.get_storage_info(user.id)

    {:ok,
     socket
     |> assign(:page_title, "Email Settings")
     |> assign(:mailbox, mailbox)
     |> assign(:unread_count, unread_count)
     |> assign(:storage_info, storage_info)
     |> assign(:active_tab, "aliases")
     |> assign(:show_modal, nil)
     |> assign(:edit_item, nil)
     |> load_tab_data("aliases")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = Map.get(params, "tab", "blocked")

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> load_tab_data(tab)}
  end

  defp load_tab_data(socket, tab) do
    user_id = socket.assigns.current_user.id

    case tab do
      "blocked" ->
        socket
        |> assign(:blocked_senders, Email.list_blocked_senders(user_id))
        |> assign(:new_blocked, %BlockedSender{})

      "safe" ->
        socket
        |> assign(:safe_senders, Email.list_safe_senders(user_id))
        |> assign(:new_safe, %SafeSender{})

      "filters" ->
        socket
        |> assign(:filters, Email.list_filters(user_id))
        |> assign(:new_filter, %Filter{
          conditions: %{"match_type" => "all", "rules" => []},
          actions: %{}
        })

      "autoreply" ->
        auto_reply = Email.get_auto_reply(user_id)

        socket
        |> assign(:auto_reply, auto_reply)
        |> assign(:auto_reply_form, to_form(Email.change_auto_reply(auto_reply, %{})))

      "templates" ->
        socket
        |> assign(:templates, Email.list_templates(user_id))
        |> assign(:new_template, %Template{})

      "folders" ->
        socket
        |> assign(:folders, Email.list_custom_folders(user_id))
        |> assign(:new_folder, %Folder{})

      "labels" ->
        socket
        |> assign(:labels, Email.list_labels(user_id))
        |> assign(:new_label, %Label{})

      "export" ->
        socket
        |> assign(:exports, Email.list_exports(user_id))

      "aliases" ->
        mailbox = Email.get_user_mailbox(user_id) || socket.assigns.mailbox

        socket
        |> assign(:mailbox, mailbox)
        |> assign(:mailbox_form, to_form(Email.change_mailbox_forwarding(mailbox)))
        |> assign(:aliases, Aliases.list_aliases(user_id))
        |> assign(:new_alias, %Alias{})

      _ ->
        socket
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/email/settings?tab=#{tab}")}
  end

  # Blocked Senders Events
  @impl true
  def handle_event("block_sender", %{"type" => type, "value" => value}, socket) do
    user_id = socket.assigns.current_user.id
    reason = nil

    result =
      case type do
        "email" -> Email.block_email(user_id, value, reason)
        "domain" -> Email.block_domain(user_id, value, reason)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sender blocked successfully")
         |> assign(:blocked_senders, Email.list_blocked_senders(user_id))}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply, put_flash(socket, :error, "Failed to block sender: #{error}")}
    end
  end

  @impl true
  def handle_event("unblock_sender", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_blocked_sender(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Blocked sender not found")}

      blocked ->
        {:ok, _} = Email.delete_blocked_sender(blocked)

        {:noreply,
         socket
         |> put_flash(:info, "Sender unblocked")
         |> assign(:blocked_senders, Email.list_blocked_senders(user_id))}
    end
  end

  # Safe Senders Events
  @impl true
  def handle_event("add_safe_sender", %{"type" => type, "value" => value}, socket) do
    user_id = socket.assigns.current_user.id

    result =
      case type do
        "email" -> Email.add_safe_email(user_id, value)
        "domain" -> Email.add_safe_domain(user_id, value)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Safe sender added successfully")
         |> assign(:safe_senders, Email.list_safe_senders(user_id))}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply, put_flash(socket, :error, "Failed to add safe sender: #{error}")}
    end
  end

  @impl true
  def handle_event("remove_safe_sender", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_safe_sender(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Safe sender not found")}

      safe ->
        {:ok, _} = Email.delete_safe_sender(safe)

        {:noreply,
         socket
         |> put_flash(:info, "Safe sender removed")
         |> assign(:safe_senders, Email.list_safe_senders(user_id))}
    end
  end

  # Filter Events
  @impl true
  def handle_event("show_filter_modal", %{"id" => "new"}, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, "filter")
     |> assign(:edit_item, nil)
     |> assign(
       :filter_form,
       build_filter_form(%Filter{
         conditions: %{
           "match_type" => "all",
           "rules" => [%{"field" => "from", "operator" => "contains", "value" => ""}]
         },
         actions: %{}
       })
     )}
  end

  @impl true
  def handle_event("show_filter_modal", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id
    filter = Email.get_filter(String.to_integer(id), user_id)

    {:noreply,
     socket
     |> assign(:show_modal, "filter")
     |> assign(:edit_item, filter)
     |> assign(:filter_form, build_filter_form(filter))}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, nil)
     |> assign(:edit_item, nil)}
  end

  @impl true
  def handle_event("save_filter", params, socket) do
    user_id = socket.assigns.current_user.id
    edit_item = socket.assigns.edit_item

    # Build conditions and actions from form params
    conditions = build_conditions_from_params(params)
    actions = build_actions_from_params(params)

    attrs = %{
      name: params["name"],
      enabled: params["enabled"] == "true",
      stop_processing: params["stop_processing"] == "true",
      conditions: conditions,
      actions: actions,
      user_id: user_id
    }

    result =
      if edit_item do
        Email.update_filter(edit_item, attrs)
      else
        Email.create_filter(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Filter saved successfully")
         |> assign(:show_modal, nil)
         |> assign(:edit_item, nil)
         |> assign(:filters, Email.list_filters(user_id))}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply, put_flash(socket, :error, "Failed to save filter: #{error}")}
    end
  end

  @impl true
  def handle_event("toggle_filter", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_filter(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Filter not found")}

      filter ->
        {:ok, _} = Email.toggle_filter(filter)

        {:noreply, assign(socket, :filters, Email.list_filters(user_id))}
    end
  end

  @impl true
  def handle_event("delete_filter", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_filter(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Filter not found")}

      filter ->
        {:ok, _} = Email.delete_filter(filter)

        {:noreply,
         socket
         |> put_flash(:info, "Filter deleted")
         |> assign(:filters, Email.list_filters(user_id))}
    end
  end

  # Auto-Reply Events
  @impl true
  def handle_event("save_auto_reply", %{"auto_reply" => params}, socket) do
    user_id = socket.assigns.current_user.id

    # Convert checkbox to boolean
    params =
      Map.merge(params, %{
        "enabled" => params["enabled"] == "true",
        "only_contacts" => params["only_contacts"] == "true",
        "exclude_mailing_lists" => params["exclude_mailing_lists"] == "true",
        "reply_once_per_sender" => params["reply_once_per_sender"] == "true"
      })

    case Email.upsert_auto_reply(user_id, params) do
      {:ok, auto_reply} ->
        {:noreply,
         socket
         |> put_flash(:info, "Auto-reply settings saved")
         |> assign(:auto_reply, auto_reply)
         |> assign(:auto_reply_form, to_form(Email.change_auto_reply(auto_reply, %{})))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save auto-reply settings")
         |> assign(:auto_reply_form, to_form(changeset))}
    end
  end

  # Template Events
  @impl true
  def handle_event("show_template_modal", %{"id" => "new"}, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, "template")
     |> assign(:edit_item, nil)
     |> assign(:template_form, to_form(%{"name" => "", "subject" => "", "body" => ""}))}
  end

  @impl true
  def handle_event("show_template_modal", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id
    template = Email.get_template(String.to_integer(id), user_id)

    {:noreply,
     socket
     |> assign(:show_modal, "template")
     |> assign(:edit_item, template)
     |> assign(
       :template_form,
       to_form(%{
         "name" => template.name,
         "subject" => template.subject || "",
         "body" => template.body
       })
     )}
  end

  @impl true
  def handle_event("save_template", params, socket) do
    user_id = socket.assigns.current_user.id
    edit_item = socket.assigns.edit_item

    attrs = %{
      name: params["name"],
      subject: params["subject"],
      body: params["body"],
      user_id: user_id
    }

    result =
      if edit_item do
        Email.update_template(edit_item, attrs)
      else
        Email.create_template(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Template saved successfully")
         |> assign(:show_modal, nil)
         |> assign(:edit_item, nil)
         |> assign(:templates, Email.list_templates(user_id))}

      {:error, :limit_reached} ->
        {:noreply, put_flash(socket, :error, "Maximum number of templates reached (50)")}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply, put_flash(socket, :error, "Failed to save template: #{error}")}
    end
  end

  @impl true
  def handle_event("delete_template", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_template(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Template not found")}

      template ->
        {:ok, _} = Email.delete_template(template)

        {:noreply,
         socket
         |> put_flash(:info, "Template deleted")
         |> assign(:templates, Email.list_templates(user_id))}
    end
  end

  # Folder Events
  @impl true
  def handle_event("create_folder", %{"name" => name, "color" => color}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.create_custom_folder(%{name: name, color: color, user_id: user_id}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Folder created successfully")
         |> assign(:folders, Email.list_custom_folders(user_id))}

      {:error, :limit_reached} ->
        {:noreply, put_flash(socket, :error, "Maximum number of folders reached (25)")}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply, put_flash(socket, :error, "Failed to create folder: #{error}")}
    end
  end

  @impl true
  def handle_event("delete_folder", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_custom_folder(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Folder not found")}

      folder ->
        {:ok, _} = Email.delete_custom_folder(folder)

        {:noreply,
         socket
         |> put_flash(:info, "Folder deleted")
         |> assign(:folders, Email.list_custom_folders(user_id))}
    end
  end

  # Label Events
  @impl true
  def handle_event("create_label", %{"name" => name, "color" => color}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.create_label(%{name: name, color: color, user_id: user_id}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Label created successfully")
         |> assign(:labels, Email.list_labels(user_id))}

      {:error, :limit_reached} ->
        {:noreply, put_flash(socket, :error, "Maximum number of labels reached (50)")}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply, put_flash(socket, :error, "Failed to create label: #{error}")}
    end
  end

  @impl true
  def handle_event("delete_label", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_label(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Label not found")}

      label ->
        {:ok, _} = Email.delete_label(label)

        {:noreply,
         socket
         |> put_flash(:info, "Label deleted")
         |> assign(:labels, Email.list_labels(user_id))}
    end
  end

  # Export Events
  @impl true
  def handle_event("start_export", %{"format" => format}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.start_export(user_id, format) do
      {:ok, _export} ->
        {:noreply,
         socket
         |> put_flash(:info, "Export started. You will be notified when it's ready.")
         |> assign(:exports, Email.list_exports(user_id))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to start export")}
    end
  end

  @impl true
  def handle_event("delete_export", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_export(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Export not found")}

      export ->
        {:ok, _} = Email.delete_export(export)

        {:noreply,
         socket
         |> put_flash(:info, "Export deleted")
         |> assign(:exports, Email.list_exports(user_id))}
    end
  end

  # Alias Events
  @impl true
  def handle_event("create_alias", params, socket) do
    user_id = socket.assigns.current_user.id
    username = params["username"]
    domain = params["domain"]
    target_email = params["target_email"]
    description = params["description"]

    alias_attrs = %{
      username: username,
      domain: domain,
      user_id: user_id,
      target_email:
        if(target_email && String.trim(target_email) != "", do: target_email, else: nil),
      description: if(description && String.trim(description) != "", do: description, else: nil)
    }

    case Aliases.create_alias(alias_attrs) do
      {:ok, _alias} ->
        {:noreply,
         socket
         |> put_flash(:info, "Alias created successfully")
         |> assign(:aliases, Aliases.list_aliases(user_id))}

      {:error, changeset} ->
        error = get_changeset_error(changeset)
        {:noreply, put_flash(socket, :error, "Failed to create alias: #{error}")}
    end
  end

  @impl true
  def handle_event("toggle_alias", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Aliases.get_alias(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Alias not found")}

      alias_record ->
        {:ok, _} = Aliases.update_alias(alias_record, %{enabled: !alias_record.enabled})
        {:noreply, assign(socket, :aliases, Aliases.list_aliases(user_id))}
    end
  end

  @impl true
  def handle_event("delete_alias", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Aliases.get_alias(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Alias not found")}

      alias_record ->
        {:ok, _} = Aliases.delete_alias(alias_record)

        {:noreply,
         socket
         |> put_flash(:info, "Alias deleted")
         |> assign(:aliases, Aliases.list_aliases(user_id))}
    end
  end

  @impl true
  def handle_event("update_mailbox_forwarding", %{"mailbox" => mailbox_params}, socket) do
    mailbox = socket.assigns.mailbox

    mailbox_params = Map.put_new(mailbox_params, "forward_enabled", "false")

    mailbox_params =
      if mailbox_params["forward_enabled"] == "true" do
        mailbox_params
      else
        Map.put(mailbox_params, "forward_to", nil)
      end

    case Email.update_mailbox_forwarding(mailbox, mailbox_params) do
      {:ok, updated_mailbox} ->
        {:noreply,
         socket
         |> put_flash(:info, "Main mailbox forwarding updated")
         |> assign(:mailbox, updated_mailbox)
         |> assign(:mailbox_form, to_form(Email.change_mailbox_forwarding(updated_mailbox)))}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply,
         socket
         |> put_flash(:error, "Failed to update mailbox forwarding: #{error}")
         |> assign(:mailbox_form, to_form(changeset))}
    end
  end

  # PubSub handlers
  @impl true
  def handle_info({:new_email, _message}, socket) do
    mailbox = socket.assigns.mailbox
    unread_count = Email.unread_count(mailbox.id)
    {:noreply, assign(socket, :unread_count, unread_count)}
  end

  def handle_info({:unread_count_updated, new_count}, socket) do
    {:noreply, assign(socket, :unread_count, new_count)}
  end

  def handle_info({:storage_updated, %{user_id: user_id}}, socket) do
    if socket.assigns.current_user.id == user_id do
      storage_info = Elektrine.Accounts.Storage.get_storage_info(user_id)
      {:noreply, assign(socket, :storage_info, storage_info)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:export_completed, _export}, socket) do
    user_id = socket.assigns.current_user.id
    exports = Email.list_exports(user_id)

    {:noreply,
     socket
     |> assign(:exports, exports)
     |> put_flash(:info, "Export completed successfully!")}
  end

  def handle_info({:export_failed, _export}, socket) do
    user_id = socket.assigns.current_user.id
    exports = Email.list_exports(user_id)

    {:noreply,
     socket
     |> assign(:exports, exports)
     |> put_flash(:error, "Export failed. Please try again.")}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Helper functions
  defp get_or_create_mailbox(user) do
    case Email.get_user_mailbox(user.id) do
      nil ->
        {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
        mailbox

      mailbox ->
        mailbox
    end
  end

  defp get_changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
  end

  defp build_filter_form(filter) do
    rules = get_in(filter.conditions, ["rules"]) || []

    first_rule =
      List.first(rules) || %{"field" => "from", "operator" => "contains", "value" => ""}

    to_form(%{
      "name" => filter.name || "",
      "enabled" => to_string(filter.enabled || true),
      "stop_processing" => to_string(filter.stop_processing || false),
      "match_type" => get_in(filter.conditions, ["match_type"]) || "all",
      "rule_field" => first_rule["field"] || "from",
      "rule_operator" => first_rule["operator"] || "contains",
      "rule_value" => first_rule["value"] || "",
      "action_mark_read" => to_string(Map.get(filter.actions, "mark_as_read", false)),
      "action_archive" => to_string(Map.get(filter.actions, "archive", false)),
      "action_spam" => to_string(Map.get(filter.actions, "mark_as_spam", false)),
      "action_delete" => to_string(Map.get(filter.actions, "delete", false)),
      "action_star" => to_string(Map.get(filter.actions, "star", false)),
      "action_priority" => Map.get(filter.actions, "set_priority", "")
    })
  end

  defp build_conditions_from_params(params) do
    %{
      "match_type" => params["match_type"] || "all",
      "rules" => [
        %{
          "field" => params["rule_field"] || "from",
          "operator" => params["rule_operator"] || "contains",
          "value" => params["rule_value"] || ""
        }
      ]
    }
  end

  defp build_actions_from_params(params) do
    actions = %{}

    actions =
      if params["action_mark_read"] == "true",
        do: Map.put(actions, "mark_as_read", true),
        else: actions

    actions =
      if params["action_archive"] == "true", do: Map.put(actions, "archive", true), else: actions

    actions =
      if params["action_spam"] == "true",
        do: Map.put(actions, "mark_as_spam", true),
        else: actions

    actions =
      if params["action_delete"] == "true", do: Map.put(actions, "delete", true), else: actions

    actions =
      if params["action_star"] == "true", do: Map.put(actions, "star", true), else: actions

    actions =
      if params["action_priority"] && params["action_priority"] != "",
        do: Map.put(actions, "set_priority", params["action_priority"]),
        else: actions

    actions
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
      <.elektrine_nav active_tab="email" />

      <div class="flex flex-col lg:flex-row gap-3 lg:gap-6 min-h-[calc(100vh-10rem)] lg:min-h-[calc(100vh-12rem)]">
        <.sidebar
          current_page="settings"
          unread_count={@unread_count}
          mailbox={@mailbox}
          storage_info={@storage_info}
          current_user={@current_user}
        />

        <div class="flex-1 min-w-0">
          <div
            id="email-settings-card"
            phx-hook="GlassCard"
            class="card glass-card shadow-lg rounded-box"
          >
            <div class="card-body p-3 sm:p-6">
              <!-- Header -->
              <div class="flex items-center space-x-2 sm:space-x-3 mb-4 sm:mb-6">
                <div class="p-1.5 sm:p-2 bg-primary/10 rounded-lg">
                  <.icon name="hero-cog-6-tooth" class="h-5 w-5 sm:h-6 sm:w-6 text-primary" />
                </div>
                <div>
                  <h1 class="text-xl sm:text-2xl font-bold">Email Settings</h1>
                  <p class="text-xs sm:text-sm text-base-content/70">
                    Manage your email preferences
                  </p>
                </div>
              </div>
              
    <!-- Tabs - scrollable on mobile -->
              <div class="overflow-x-auto -mx-3 sm:-mx-6 px-3 sm:px-6 mb-4 sm:mb-6">
                <div class="tabs tabs-boxed inline-flex min-w-max">
                  <button
                    phx-click="switch_tab"
                    phx-value-tab="aliases"
                    class={["tab tab-sm sm:tab-md", @active_tab == "aliases" && "tab-active"]}
                  >
                    Aliases
                  </button>
                  <button
                    phx-click="switch_tab"
                    phx-value-tab="blocked"
                    class={["tab tab-sm sm:tab-md", @active_tab == "blocked" && "tab-active"]}
                  >
                    Blocked
                  </button>
                  <button
                    phx-click="switch_tab"
                    phx-value-tab="safe"
                    class={["tab tab-sm sm:tab-md", @active_tab == "safe" && "tab-active"]}
                  >
                    Safe
                  </button>
                  <button
                    phx-click="switch_tab"
                    phx-value-tab="filters"
                    class={["tab tab-sm sm:tab-md", @active_tab == "filters" && "tab-active"]}
                  >
                    Filters
                  </button>
                  <button
                    phx-click="switch_tab"
                    phx-value-tab="autoreply"
                    class={["tab tab-sm sm:tab-md", @active_tab == "autoreply" && "tab-active"]}
                  >
                    Auto-Reply
                  </button>
                  <button
                    phx-click="switch_tab"
                    phx-value-tab="templates"
                    class={["tab tab-sm sm:tab-md", @active_tab == "templates" && "tab-active"]}
                  >
                    Templates
                  </button>
                  <button
                    phx-click="switch_tab"
                    phx-value-tab="folders"
                    class={["tab tab-sm sm:tab-md", @active_tab == "folders" && "tab-active"]}
                  >
                    Folders
                  </button>
                  <button
                    phx-click="switch_tab"
                    phx-value-tab="labels"
                    class={["tab tab-sm sm:tab-md", @active_tab == "labels" && "tab-active"]}
                  >
                    Labels
                  </button>
                  <button
                    phx-click="switch_tab"
                    phx-value-tab="export"
                    class={["tab tab-sm sm:tab-md", @active_tab == "export" && "tab-active"]}
                  >
                    Export
                  </button>
                </div>
              </div>
              
    <!-- Tab Content -->
              <%= case @active_tab do %>
                <% "blocked" -> %>
                  {render_blocked_tab(assigns)}
                <% "safe" -> %>
                  {render_safe_tab(assigns)}
                <% "filters" -> %>
                  {render_filters_tab(assigns)}
                <% "autoreply" -> %>
                  {render_autoreply_tab(assigns)}
                <% "templates" -> %>
                  {render_templates_tab(assigns)}
                <% "folders" -> %>
                  {render_folders_tab(assigns)}
                <% "labels" -> %>
                  {render_labels_tab(assigns)}
                <% "export" -> %>
                  {render_export_tab(assigns)}
                <% "aliases" -> %>
                  {render_aliases_tab(assigns)}
                <% _ -> %>
                  <p>Select a tab</p>
              <% end %>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Modals -->
      <%= if @show_modal do %>
        {render_modal(assigns)}
      <% end %>
    </div>
    """
  end

  defp render_blocked_tab(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Blocked Senders</h2>
      <p class="text-base-content/70 mb-4">
        Emails from blocked addresses or domains will be automatically rejected.
      </p>
      
    <!-- Add Form -->
      <form phx-submit="block_sender" class="flex gap-2 mb-6">
        <select name="type" class="select select-bordered">
          <option value="email">Email Address</option>
          <option value="domain">Domain</option>
        </select>
        <input
          type="text"
          name="value"
          placeholder="email@example.com or example.com"
          class="input input-bordered flex-1"
          required
        />
        <button type="submit" class="btn btn-primary">Block</button>
      </form>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for blocked <- @blocked_senders do %>
          <div class="flex items-center justify-between p-3 bg-base-100/50 rounded-lg border border-base-content/10">
            <div>
              <%= if blocked.email do %>
                <span class="badge badge-ghost mr-2">Email</span>
                <span>{blocked.email}</span>
              <% else %>
                <span class="badge badge-ghost mr-2">Domain</span>
                <span>{blocked.domain}</span>
              <% end %>
              <%= if blocked.reason do %>
                <span class="text-sm text-base-content/50 ml-2">({blocked.reason})</span>
              <% end %>
            </div>
            <button
              phx-click="unblock_sender"
              phx-value-id={blocked.id}
              class="btn btn-ghost btn-sm text-error"
            >
              Unblock
            </button>
          </div>
        <% end %>
        <%= if Enum.empty?(@blocked_senders) do %>
          <p class="text-base-content/50 text-center py-4">No blocked senders</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_safe_tab(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Safe Senders</h2>
      <p class="text-base-content/70 mb-4">
        Emails from safe senders will never be marked as spam.
      </p>
      
    <!-- Add Form -->
      <form phx-submit="add_safe_sender" class="flex gap-2 mb-6">
        <select name="type" class="select select-bordered">
          <option value="email">Email Address</option>
          <option value="domain">Domain</option>
        </select>
        <input
          type="text"
          name="value"
          placeholder="email@example.com or example.com"
          class="input input-bordered flex-1"
          required
        />
        <button type="submit" class="btn btn-primary">Add</button>
      </form>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for safe <- @safe_senders do %>
          <div class="flex items-center justify-between p-3 bg-base-100/50 rounded-lg border border-base-content/10">
            <div>
              <%= if safe.email do %>
                <span class="badge badge-ghost mr-2">Email</span>
                <span>{safe.email}</span>
              <% else %>
                <span class="badge badge-ghost mr-2">Domain</span>
                <span>{safe.domain}</span>
              <% end %>
            </div>
            <button
              phx-click="remove_safe_sender"
              phx-value-id={safe.id}
              class="btn btn-ghost btn-sm text-error"
            >
              Remove
            </button>
          </div>
        <% end %>
        <%= if Enum.empty?(@safe_senders) do %>
          <p class="text-base-content/50 text-center py-4">No safe senders</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_filters_tab(assigns) do
    ~H"""
    <div>
      <div class="flex justify-between items-center mb-4">
        <div>
          <h2 class="text-xl font-semibold">Email Filters</h2>
          <p class="text-base-content/70">
            Automatically organize incoming emails based on rules.
          </p>
        </div>
        <button phx-click="show_filter_modal" phx-value-id="new" class="btn btn-primary">
          Create Filter
        </button>
      </div>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for filter <- @filters do %>
          <div class="flex items-center justify-between p-3 bg-base-100/50 rounded-lg border border-base-content/10">
            <div class="flex items-center gap-3">
              <input
                type="checkbox"
                checked={filter.enabled}
                phx-click="toggle_filter"
                phx-value-id={filter.id}
                class="checkbox checkbox-sm"
              />
              <div>
                <span class="font-medium">{filter.name}</span>
                <div class="text-sm text-base-content/50">
                  {describe_filter(filter)}
                </div>
              </div>
            </div>
            <div class="flex gap-2">
              <button
                phx-click="show_filter_modal"
                phx-value-id={filter.id}
                class="btn btn-ghost btn-sm"
              >
                Edit
              </button>
              <button
                phx-click="delete_filter"
                phx-value-id={filter.id}
                class="btn btn-ghost btn-sm text-error"
                data-confirm="Are you sure you want to delete this filter?"
              >
                Delete
              </button>
            </div>
          </div>
        <% end %>
        <%= if Enum.empty?(@filters) do %>
          <p class="text-base-content/50 text-center py-4">No filters created</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_autoreply_tab(assigns) do
    ~H"""
    <div>
      <.form for={@auto_reply_form} phx-submit="save_auto_reply" class="space-y-6">
        <!-- Status Toggle -->
        <div class="flex items-center justify-between p-4 bg-base-200/50 rounded-lg border border-base-content/10">
          <div class="flex items-center gap-3">
            <div class={["p-2 rounded-lg", (@auto_reply.enabled && "bg-success/20") || "bg-base-300"]}>
              <.icon
                name={if @auto_reply.enabled, do: "hero-paper-airplane", else: "hero-pause"}
                class={["h-5 w-5", (@auto_reply.enabled && "text-success") || "text-base-content/50"]}
              />
            </div>
            <div>
              <p class="font-medium">Auto-Reply Status</p>
              <p class="text-sm text-base-content/60">
                {if @auto_reply.enabled, do: "Sending automatic replies", else: "Currently disabled"}
              </p>
            </div>
          </div>
          <label class="cursor-pointer">
            <input
              type="checkbox"
              name="auto_reply[enabled]"
              value="true"
              checked={@auto_reply.enabled}
              class="toggle toggle-success toggle-lg"
            />
          </label>
        </div>

        <div class="divider text-xs text-base-content/50 my-2">SCHEDULE</div>
        
    <!-- Schedule Section -->
        <div class="bg-base-200/50 rounded-lg p-4 space-y-4">
          <p class="text-sm text-base-content/60 mb-3">
            <.icon name="hero-calendar" class="h-4 w-4 inline mr-1" />
            Leave dates empty to run indefinitely when enabled
          </p>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div class="form-control">
              <label class="label pb-1">
                <span class="label-text font-medium">Start Date</span>
                <span class="label-text-alt text-base-content/50">Optional</span>
              </label>
              <input
                type="date"
                name="auto_reply[start_date]"
                value={@auto_reply.start_date}
                class="input input-bordered w-full"
              />
            </div>
            <div class="form-control">
              <label class="label pb-1">
                <span class="label-text font-medium">End Date</span>
                <span class="label-text-alt text-base-content/50">Optional</span>
              </label>
              <input
                type="date"
                name="auto_reply[end_date]"
                value={@auto_reply.end_date}
                class="input input-bordered w-full"
              />
            </div>
          </div>
        </div>

        <div class="divider text-xs text-base-content/50 my-2">MESSAGE</div>
        
    <!-- Message Section -->
        <div class="space-y-4">
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-medium">Subject Line</span>
              <span class="label-text-alt text-base-content/50">Optional</span>
            </label>
            <input
              type="text"
              name="auto_reply[subject]"
              value={@auto_reply.subject}
              placeholder="e.g., Out of Office: Re: Your message"
              class="input input-bordered w-full"
            />
          </div>

          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-medium">Auto-Reply Message</span>
              <span class="label-text-alt text-base-content/50">Required</span>
            </label>
            <textarea
              name="auto_reply[body]"
              rows="8"
              required
              class="textarea textarea-bordered w-full"
              placeholder="Thank you for your email. I'm currently out of the office with limited access to email. I will return on [date] and will respond to your message as soon as possible."
            ><%= @auto_reply.body %></textarea>
          </div>
        </div>

        <div class="divider text-xs text-base-content/50 my-2">ADVANCED OPTIONS</div>
        
    <!-- Options Section -->
        <div class="bg-base-200/50 rounded-lg p-4">
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <label class="flex items-center gap-3 cursor-pointer p-3 rounded-lg hover:bg-base-300/50 transition-colors border border-transparent hover:border-base-content/10">
              <input
                type="checkbox"
                name="auto_reply[only_contacts]"
                value="true"
                checked={@auto_reply.only_contacts}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <div>
                <p class="text-sm font-medium">Contacts only</p>
                <p class="text-xs text-base-content/50">Reply only to known contacts</p>
              </div>
            </label>
            <label class="flex items-center gap-3 cursor-pointer p-3 rounded-lg hover:bg-base-300/50 transition-colors border border-transparent hover:border-base-content/10">
              <input
                type="checkbox"
                name="auto_reply[exclude_mailing_lists]"
                value="true"
                checked={@auto_reply.exclude_mailing_lists}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <div>
                <p class="text-sm font-medium">Skip mailing lists</p>
                <p class="text-xs text-base-content/50">Don't reply to list emails</p>
              </div>
            </label>
            <label class="flex items-center gap-3 cursor-pointer p-3 rounded-lg hover:bg-base-300/50 transition-colors border border-transparent hover:border-base-content/10">
              <input
                type="checkbox"
                name="auto_reply[reply_once_per_sender]"
                value="true"
                checked={@auto_reply.reply_once_per_sender}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <div>
                <p class="text-sm font-medium">Once per sender</p>
                <p class="text-xs text-base-content/50">One reply per person</p>
              </div>
            </label>
          </div>
        </div>
        
    <!-- Save Button -->
        <div class="flex justify-end pt-4 border-t border-base-content/10">
          <button type="submit" class="btn btn-primary">
            <.icon name="hero-check" class="h-4 w-4" /> Save Settings
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp render_templates_tab(assigns) do
    ~H"""
    <div>
      <div class="flex justify-between items-center mb-4">
        <div>
          <h2 class="text-xl font-semibold">Email Templates</h2>
          <p class="text-base-content/70">
            Save commonly used email templates for quick access.
          </p>
        </div>
        <button phx-click="show_template_modal" phx-value-id="new" class="btn btn-primary">
          Create Template
        </button>
      </div>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for template <- @templates do %>
          <div class="flex items-center justify-between p-3 bg-base-100/50 rounded-lg border border-base-content/10">
            <div>
              <span class="font-medium">{template.name}</span>
              <%= if template.subject do %>
                <div class="text-sm text-base-content/50">{template.subject}</div>
              <% end %>
            </div>
            <div class="flex gap-2">
              <button
                phx-click="show_template_modal"
                phx-value-id={template.id}
                class="btn btn-ghost btn-sm"
              >
                Edit
              </button>
              <button
                phx-click="delete_template"
                phx-value-id={template.id}
                class="btn btn-ghost btn-sm text-error"
                data-confirm="Are you sure you want to delete this template?"
              >
                Delete
              </button>
            </div>
          </div>
        <% end %>
        <%= if Enum.empty?(@templates) do %>
          <p class="text-base-content/50 text-center py-4">No templates created</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_folders_tab(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Custom Folders</h2>
      <p class="text-base-content/70 mb-4">
        Create custom folders to organize your emails.
      </p>
      
    <!-- Add Form -->
      <form phx-submit="create_folder" class="flex gap-2 mb-6">
        <input
          type="text"
          name="name"
          placeholder="Folder name"
          class="input input-bordered flex-1"
          required
        />
        <select name="color" class="select select-bordered">
          <option value="#3b82f6">Blue</option>
          <option value="#22c55e">Green</option>
          <option value="#ef4444">Red</option>
          <option value="#f59e0b">Orange</option>
          <option value="#8b5cf6">Purple</option>
          <option value="#ec4899">Pink</option>
          <option value="#6b7280">Gray</option>
        </select>
        <button type="submit" class="btn btn-primary">Create</button>
      </form>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for folder <- @folders do %>
          <div class="flex items-center justify-between p-3 bg-base-100/50 rounded-lg border border-base-content/10">
            <div class="flex items-center gap-2">
              <div
                class="w-3 h-3 rounded-full"
                style={"background-color: #{folder.color || "#3b82f6"}"}
              >
              </div>
              <span class="font-medium">{folder.name}</span>
            </div>
            <button
              phx-click="delete_folder"
              phx-value-id={folder.id}
              class="btn btn-ghost btn-sm text-error"
              data-confirm="Are you sure? Messages in this folder will be moved to inbox."
            >
              Delete
            </button>
          </div>
        <% end %>
        <%= if Enum.empty?(@folders) do %>
          <p class="text-base-content/50 text-center py-4">No custom folders</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_labels_tab(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Labels</h2>
      <p class="text-base-content/70 mb-4">
        Create labels to tag and categorize your emails.
      </p>
      
    <!-- Add Form -->
      <form phx-submit="create_label" class="flex gap-2 mb-6">
        <input
          type="text"
          name="name"
          placeholder="Label name"
          class="input input-bordered flex-1"
          required
        />
        <select name="color" class="select select-bordered">
          <option value="#3b82f6">Blue</option>
          <option value="#22c55e">Green</option>
          <option value="#ef4444">Red</option>
          <option value="#f59e0b">Orange</option>
          <option value="#8b5cf6">Purple</option>
          <option value="#ec4899">Pink</option>
          <option value="#6b7280">Gray</option>
        </select>
        <button type="submit" class="btn btn-primary">Create</button>
      </form>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for label <- @labels do %>
          <div class="flex items-center justify-between p-3 bg-base-100/50 rounded-lg border border-base-content/10">
            <div class="flex items-center gap-2">
              <div class="w-3 h-3 rounded-full" style={"background-color: #{label.color}"}></div>
              <span class="font-medium">{label.name}</span>
            </div>
            <button
              phx-click="delete_label"
              phx-value-id={label.id}
              class="btn btn-ghost btn-sm text-error"
              data-confirm="Are you sure? This label will be removed from all messages."
            >
              Delete
            </button>
          </div>
        <% end %>
        <%= if Enum.empty?(@labels) do %>
          <p class="text-base-content/50 text-center py-4">No labels created</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_export_tab(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Export Emails</h2>
      <p class="text-base-content/70 mb-4">
        Download a backup of your emails.
      </p>
      
    <!-- Export Options -->
      <div class="flex gap-4 mb-6">
        <button phx-click="start_export" phx-value-format="mbox" class="btn btn-primary">
          Export as MBOX
        </button>
        <button phx-click="start_export" phx-value-format="zip" class="btn btn-outline">
          Export as ZIP (EML files)
        </button>
      </div>
      
    <!-- Export History -->
      <h3 class="font-semibold mb-2">Export History</h3>
      <div class="space-y-2">
        <%= for export <- @exports do %>
          <div class="flex items-center justify-between p-3 bg-base-100/50 rounded-lg border border-base-content/10">
            <div>
              <span class="font-medium">{export.format |> String.upcase()}</span>
              <span class={"badge badge-sm ml-2 badge-#{status_color(export.status)}"}>
                {export.status}
              </span>
              <%= if export.message_count do %>
                <span class="text-sm text-base-content/50 ml-2">
                  ({export.message_count} messages)
                </span>
              <% end %>
              <div class="text-sm text-base-content/50">
                {Calendar.strftime(export.inserted_at, "%b %d, %Y %H:%M")}
              </div>
            </div>
            <div class="flex gap-2">
              <%= if export.status == "completed" && export.file_path do %>
                <a
                  href={~p"/email/export/download/#{export.id}"}
                  class="btn btn-ghost btn-sm"
                  download
                >
                  Download
                </a>
              <% end %>
              <button
                phx-click="delete_export"
                phx-value-id={export.id}
                class="btn btn-ghost btn-sm text-error"
              >
                Delete
              </button>
            </div>
          </div>
        <% end %>
        <%= if Enum.empty?(@exports) do %>
          <p class="text-base-content/50 text-center py-4">No exports yet</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_aliases_tab(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Email Aliases</h2>
      <p class="text-base-content/70 mb-6">
        Create additional email addresses that deliver to your mailbox or forward elsewhere. You can have up to 15 aliases.
      </p>

      <.form
        for={@mailbox_form}
        as={:mailbox}
        phx-submit="update_mailbox_forwarding"
        class="card space-y-4 mb-8 p-5"
      >
        <h3 class="font-semibold text-lg mb-1">Main Email Forwarding</h3>
        <p class="text-sm text-base-content/60">
          Forward all emails sent to your primary mailbox addresses.
        </p>

        <div class="flex flex-wrap gap-2">
          <%= if @mailbox.username do %>
            <span class="badge badge-outline">{@mailbox.username}@elektrine.com</span>
            <span class="badge badge-outline">{@mailbox.username}@z.org</span>
          <% else %>
            <span class="badge badge-outline">{@mailbox.email}</span>
          <% end %>
        </div>

        <div class="flex items-center justify-between p-3 bg-base-200/40 rounded-lg">
          <label class="label cursor-pointer gap-3 p-0">
            <span class="label-text font-medium">Enable Forwarding</span>
            <input type="hidden" name="mailbox[forward_enabled]" value="false" />
            <input
              type="checkbox"
              name="mailbox[forward_enabled]"
              value="true"
              checked={@mailbox.forward_enabled}
              class="toggle toggle-primary"
            />
          </label>
        </div>

        <div>
          <label class="label pb-1">
            <span class="label-text font-medium">Forward to Email</span>
          </label>
          <input
            type="email"
            name="mailbox[forward_to]"
            value={@mailbox_form[:forward_to].value || ""}
            placeholder="your.email@example.com"
            class="input input-bordered w-full"
          />
          <div class="text-xs text-base-content/50 mt-1">
            Required when forwarding is enabled.
          </div>
        </div>

        <%= if @mailbox.forward_enabled && @mailbox.forward_to && String.trim(@mailbox.forward_to) != "" do %>
          <div class="alert alert-info py-2 px-3">
            <span class="text-sm">
              Forwarding active: mail to your main mailbox goes to {@mailbox.forward_to}
            </span>
          </div>
        <% end %>

        <div class="flex justify-end">
          <button type="submit" class="btn btn-primary">Save Main Forwarding</button>
        </div>
      </.form>
      
    <!-- Add Form -->
      <form phx-submit="create_alias" class="card space-y-4 mb-8 p-5">
        <h3 class="font-semibold text-lg mb-4">Create New Alias</h3>
        
    <!-- Alias Address Row -->
        <div>
          <label class="label pb-1">
            <span class="label-text font-medium">Alias Address</span>
          </label>
          <div class="flex flex-col sm:flex-row gap-2">
            <input
              type="text"
              name="username"
              placeholder="myalias"
              class="input input-bordered sm:flex-1 text-lg"
              pattern="[a-zA-Z0-9]+"
              title="Only letters and numbers allowed"
              minlength="4"
              maxlength="30"
              required
            />
            <div class="flex items-center gap-2">
              <span class="text-base-content/50 text-lg">@</span>
              <select name="domain" class="select select-bordered text-lg">
                <option value="elektrine.com">elektrine.com</option>
                <option value="z.org">z.org</option>
              </select>
            </div>
          </div>
          <div class="text-xs text-base-content/50 mt-1">
            4-30 characters, letters and numbers only
          </div>
        </div>
        
    <!-- Forward To Row -->
        <div>
          <label class="label pb-1">
            <span class="label-text font-medium">Forward To (optional)</span>
          </label>
          <input
            type="email"
            name="target_email"
            placeholder="your.personal@gmail.com"
            class="input input-bordered w-full"
          />
          <div class="text-xs text-base-content/50 mt-1">
            Leave empty to deliver emails to your main mailbox
          </div>
        </div>
        
    <!-- Description Row -->
        <div>
          <label class="label pb-1">
            <span class="label-text font-medium">Description (optional)</span>
          </label>
          <input
            type="text"
            name="description"
            placeholder="e.g., Shopping accounts, newsletters, work stuff..."
            class="input input-bordered w-full"
            maxlength="500"
          />
        </div>
        <div class="flex justify-end">
          <button type="submit" class="btn btn-primary">Create Alias</button>
        </div>
      </form>
      
    <!-- List -->
      <%= if !Enum.empty?(@aliases) do %>
        <h3 class="font-semibold text-lg mb-3">Your Aliases</h3>
      <% end %>
      <div class="space-y-3">
        <%= for alias_record <- @aliases do %>
          <div class="card p-4">
            <div class="flex items-start justify-between gap-4">
              <div class="flex items-start gap-4 flex-1">
                <label class="swap cursor-pointer mt-0.5">
                  <input
                    type="checkbox"
                    checked={alias_record.enabled}
                    phx-click="toggle_alias"
                    phx-value-id={alias_record.id}
                  />
                  <div class="swap-on">
                    <.icon name="hero-check-circle-solid" class="w-6 h-6 text-success" />
                  </div>
                  <div class="swap-off">
                    <.icon name="hero-x-circle-solid" class="w-6 h-6 text-base-content/30" />
                  </div>
                </label>
                <div class="flex-1 min-w-0">
                  <div class="flex flex-col sm:flex-row sm:items-center gap-1 sm:gap-3">
                    <span class="font-semibold text-lg">{alias_record.alias_email}</span>
                    <%= if alias_record.target_email && String.trim(alias_record.target_email) != "" do %>
                      <div class="flex items-center gap-2 text-base-content/60">
                        <.icon name="hero-arrow-right" class="w-4 h-4" />
                        <span class="text-sm">{alias_record.target_email}</span>
                      </div>
                    <% else %>
                      <span class="badge badge-ghost gap-1">
                        <.icon name="hero-inbox" class="w-3 h-3" /> Main Mailbox
                      </span>
                    <% end %>
                  </div>
                  <%= if alias_record.description && String.trim(alias_record.description) != "" do %>
                    <p class="text-sm text-base-content/50 mt-1">{alias_record.description}</p>
                  <% end %>
                  <%= if !alias_record.enabled do %>
                    <div class="mt-2">
                      <span class="badge badge-sm badge-warning gap-1">
                        <.icon name="hero-pause" class="w-3 h-3" /> Disabled
                      </span>
                    </div>
                  <% end %>
                </div>
              </div>
              <button
                phx-click="delete_alias"
                phx-value-id={alias_record.id}
                class="btn btn-ghost btn-sm text-error hover:bg-error/10"
                data-confirm="Are you sure you want to delete this alias?"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            </div>
          </div>
        <% end %>
        <%= if Enum.empty?(@aliases) do %>
          <div class="text-center py-12 bg-base-200/30 rounded-xl border border-dashed border-base-content/20">
            <.icon name="hero-at-symbol" class="w-12 h-12 mx-auto text-base-content/30 mb-3" />
            <p class="text-base-content/50">No aliases created yet</p>
            <p class="text-sm text-base-content/40 mt-1">Create your first alias above</p>
          </div>
        <% end %>
      </div>
      
    <!-- Info -->
      <div class="card mt-6 p-4">
        <div class="flex gap-3">
          <.icon name="hero-information-circle" class="h-5 w-5 text-info flex-shrink-0 mt-0.5" />
          <div class="text-sm">
            <p class="font-medium text-info">How aliases work</p>
            <p class="text-base-content/70 mt-1">
              Emails sent to your aliases will be delivered to your main mailbox unless you specify a forwarding address.
              You can disable an alias to stop receiving emails without deleting it.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl border border-purple-500/30">
        <%= case @show_modal do %>
          <% "filter" -> %>
            <!-- Header -->
            <div class="flex items-center justify-between mb-6">
              <div class="flex items-center gap-3">
                <div class="p-2 bg-primary/10 rounded-lg">
                  <.icon name="hero-funnel" class="h-5 w-5 text-primary" />
                </div>
                <div>
                  <h3 class="font-bold text-lg">
                    {if @edit_item, do: "Edit Filter", else: "Create Filter"}
                  </h3>
                  <p class="text-sm text-base-content/60">Automatically organize incoming emails</p>
                </div>
              </div>
              <button type="button" phx-click="close_modal" class="btn btn-ghost btn-sm btn-circle">
                <.icon name="hero-x-mark" class="h-5 w-5" />
              </button>
            </div>

            <form phx-submit="save_filter" class="space-y-6">
              <!-- Basic Info -->
              <div class="form-control">
                <label class="label pb-1">
                  <span class="label-text font-medium">Filter Name</span>
                </label>
                <input
                  type="text"
                  name="name"
                  value={@filter_form[:name].value}
                  class="input input-bordered w-full"
                  placeholder="e.g., Newsletter emails"
                  required
                />
              </div>

              <div class="divider text-xs text-base-content/50 my-2">CONDITIONS</div>
              
    <!-- Conditions Section -->
              <div class="bg-base-200/50 rounded-lg p-4 space-y-4">
                <div class="form-control">
                  <label class="label pb-1">
                    <span class="label-text font-medium">Match Type</span>
                  </label>
                  <select name="match_type" class="select select-bordered w-full">
                    <option value="all" selected={@filter_form[:match_type].value == "all"}>
                      All conditions must match
                    </option>
                    <option value="any" selected={@filter_form[:match_type].value == "any"}>
                      Any condition can match
                    </option>
                  </select>
                </div>

                <div class="form-control">
                  <label class="label pb-1">
                    <span class="label-text font-medium">Condition</span>
                  </label>
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
                    <select name="rule_field" class="select select-bordered">
                      <option value="from" selected={@filter_form[:rule_field].value == "from"}>
                        From
                      </option>
                      <option value="to" selected={@filter_form[:rule_field].value == "to"}>
                        To
                      </option>
                      <option value="subject" selected={@filter_form[:rule_field].value == "subject"}>
                        Subject
                      </option>
                      <option value="body" selected={@filter_form[:rule_field].value == "body"}>
                        Body
                      </option>
                    </select>
                    <select name="rule_operator" class="select select-bordered">
                      <option
                        value="contains"
                        selected={@filter_form[:rule_operator].value == "contains"}
                      >
                        contains
                      </option>
                      <option
                        value="not_contains"
                        selected={@filter_form[:rule_operator].value == "not_contains"}
                      >
                        doesn't contain
                      </option>
                      <option value="equals" selected={@filter_form[:rule_operator].value == "equals"}>
                        equals
                      </option>
                      <option
                        value="starts_with"
                        selected={@filter_form[:rule_operator].value == "starts_with"}
                      >
                        starts with
                      </option>
                      <option
                        value="ends_with"
                        selected={@filter_form[:rule_operator].value == "ends_with"}
                      >
                        ends with
                      </option>
                    </select>
                    <input
                      type="text"
                      name="rule_value"
                      value={@filter_form[:rule_value].value}
                      class="input input-bordered"
                      placeholder="Value..."
                    />
                  </div>
                </div>
              </div>

              <div class="divider text-xs text-base-content/50 my-2">ACTIONS</div>
              
    <!-- Actions Section -->
              <div class="bg-base-200/50 rounded-lg p-4">
                <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
                  <label class="flex items-center gap-2 cursor-pointer p-2 rounded hover:bg-base-300/50 transition-colors">
                    <input
                      type="checkbox"
                      name="action_mark_read"
                      value="true"
                      checked={@filter_form[:action_mark_read].value == "true"}
                      class="checkbox checkbox-sm checkbox-primary"
                    />
                    <span class="text-sm">Mark as read</span>
                  </label>
                  <label class="flex items-center gap-2 cursor-pointer p-2 rounded hover:bg-base-300/50 transition-colors">
                    <input
                      type="checkbox"
                      name="action_archive"
                      value="true"
                      checked={@filter_form[:action_archive].value == "true"}
                      class="checkbox checkbox-sm checkbox-primary"
                    />
                    <span class="text-sm">Archive</span>
                  </label>
                  <label class="flex items-center gap-2 cursor-pointer p-2 rounded hover:bg-base-300/50 transition-colors">
                    <input
                      type="checkbox"
                      name="action_star"
                      value="true"
                      checked={@filter_form[:action_star].value == "true"}
                      class="checkbox checkbox-sm checkbox-primary"
                    />
                    <span class="text-sm">Star</span>
                  </label>
                  <label class="flex items-center gap-2 cursor-pointer p-2 rounded hover:bg-base-300/50 transition-colors">
                    <input
                      type="checkbox"
                      name="action_spam"
                      value="true"
                      checked={@filter_form[:action_spam].value == "true"}
                      class="checkbox checkbox-sm checkbox-warning"
                    />
                    <span class="text-sm">Mark as spam</span>
                  </label>
                  <label class="flex items-center gap-2 cursor-pointer p-2 rounded hover:bg-base-300/50 transition-colors">
                    <input
                      type="checkbox"
                      name="action_delete"
                      value="true"
                      checked={@filter_form[:action_delete].value == "true"}
                      class="checkbox checkbox-sm checkbox-error"
                    />
                    <span class="text-sm">Delete</span>
                  </label>
                  <div class="flex items-center gap-2 p-2">
                    <span class="text-sm text-base-content/70">Priority:</span>
                    <select name="action_priority" class="select select-bordered select-sm flex-1">
                      <option value="">None</option>
                      <option value="high" selected={@filter_form[:action_priority].value == "high"}>
                        High
                      </option>
                      <option
                        value="normal"
                        selected={@filter_form[:action_priority].value == "normal"}
                      >
                        Normal
                      </option>
                      <option value="low" selected={@filter_form[:action_priority].value == "low"}>
                        Low
                      </option>
                    </select>
                  </div>
                </div>
              </div>

              <div class="divider text-xs text-base-content/50 my-2">OPTIONS</div>
              
    <!-- Options Section -->
              <div class="flex flex-col sm:flex-row sm:items-center gap-4">
                <label class="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="enabled"
                    value="true"
                    checked={@filter_form[:enabled].value == "true"}
                    class="toggle toggle-primary toggle-sm"
                  />
                  <span class="text-sm font-medium">Enable filter</span>
                </label>
                <label class="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="stop_processing"
                    value="true"
                    checked={@filter_form[:stop_processing].value == "true"}
                    class="toggle toggle-sm"
                  />
                  <span class="text-sm">Stop processing other filters</span>
                </label>
              </div>
              
    <!-- Footer -->
              <div class="flex justify-end gap-2 pt-4 border-t border-base-content/10">
                <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancel</button>
                <button type="submit" class="btn btn-primary">
                  <.icon name="hero-check" class="h-4 w-4" /> Save Filter
                </button>
              </div>
            </form>
          <% "template" -> %>
            <!-- Header -->
            <div class="flex items-center justify-between mb-6">
              <div class="flex items-center gap-3">
                <div class="p-2 bg-primary/10 rounded-lg">
                  <.icon name="hero-document-text" class="h-5 w-5 text-primary" />
                </div>
                <div>
                  <h3 class="font-bold text-lg">
                    {if @edit_item, do: "Edit Template", else: "Create Template"}
                  </h3>
                  <p class="text-sm text-base-content/60">Save commonly used email content</p>
                </div>
              </div>
              <button type="button" phx-click="close_modal" class="btn btn-ghost btn-sm btn-circle">
                <.icon name="hero-x-mark" class="h-5 w-5" />
              </button>
            </div>

            <form phx-submit="save_template" class="space-y-5">
              <div class="form-control">
                <label class="label pb-1">
                  <span class="label-text font-medium">Template Name</span>
                  <span class="label-text-alt text-base-content/50">Required</span>
                </label>
                <input
                  type="text"
                  name="name"
                  value={@template_form[:name].value}
                  class="input input-bordered w-full"
                  placeholder="e.g., Meeting follow-up"
                  required
                />
              </div>

              <div class="form-control">
                <label class="label pb-1">
                  <span class="label-text font-medium">Subject Line</span>
                  <span class="label-text-alt text-base-content/50">Optional</span>
                </label>
                <input
                  type="text"
                  name="subject"
                  value={@template_form[:subject].value}
                  class="input input-bordered w-full"
                  placeholder="e.g., Following up on our meeting"
                />
              </div>

              <div class="form-control">
                <label class="label pb-1">
                  <span class="label-text font-medium">Email Body</span>
                  <span class="label-text-alt text-base-content/50">Required</span>
                </label>
                <textarea
                  name="body"
                  rows="10"
                  class="textarea textarea-bordered w-full font-mono text-sm"
                  placeholder="Write your template content here..."
                  required
                ><%= @template_form[:body].value %></textarea>
                <label class="label pt-1">
                  <span class="label-text-alt text-base-content/50">
                    Tip: You can use this template when composing new emails
                  </span>
                </label>
              </div>
              
    <!-- Footer -->
              <div class="flex justify-end gap-2 pt-4 border-t border-base-content/10">
                <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancel</button>
                <button type="submit" class="btn btn-primary">
                  <.icon name="hero-check" class="h-4 w-4" /> Save Template
                </button>
              </div>
            </form>
          <% _ -> %>
            <p>Unknown modal</p>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop bg-black/50">
        <button phx-click="close_modal">close</button>
      </form>
    </div>
    """
  end

  defp describe_filter(filter) do
    rules = get_in(filter.conditions, ["rules"]) || []
    actions = filter.actions || %{}

    rule_desc =
      rules
      |> Enum.map(fn rule ->
        "#{rule["field"]} #{rule["operator"]} '#{rule["value"]}'"
      end)
      |> Enum.map_join(", ", & &1)

    action_desc =
      actions
      |> Enum.map(fn
        {"mark_as_read", true} -> "mark read"
        {"archive", true} -> "archive"
        {"mark_as_spam", true} -> "spam"
        {"delete", true} -> "delete"
        {"star", true} -> "star"
        {"set_priority", p} -> "priority: #{p}"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "If #{rule_desc} then #{action_desc}"
  end

  defp status_color("completed"), do: "success"
  defp status_color("processing"), do: "info"
  defp status_color("failed"), do: "error"
  defp status_color(_), do: "ghost"
end
