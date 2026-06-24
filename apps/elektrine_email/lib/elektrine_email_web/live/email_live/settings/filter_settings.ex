defmodule ElektrineEmailWeb.EmailLive.Settings.FilterSettings do
  @moduledoc """
  Filter, mailbox category filter, and auto-reply settings: event handlers,
  tab data loading, and per-tab render functions for
  `ElektrineEmailWeb.EmailLive.Settings`.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [put_flash: 3]
  import ElektrineWeb.CoreComponents
  import ElektrineEmailWeb.EmailLive.Settings.Helpers

  alias Elektrine.Email
  alias Elektrine.Email.Filter

  # Tab data loading

  def load_tab_data(socket, "filters") do
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:filters, Email.list_filters(user_id))
    |> assign(
      :mailbox_filter_form,
      to_form(Email.change_mailbox_category_filters(socket.assigns.mailbox), as: :mailbox)
    )
    |> assign(:new_filter, %Filter{
      conditions: %{"match_type" => "all", "rules" => []},
      actions: %{}
    })
  end

  def load_tab_data(socket, "autoreply") do
    user_id = socket.assigns.current_user.id
    auto_reply = Email.get_auto_reply(user_id)

    socket
    |> assign(:auto_reply, auto_reply)
    |> assign(:auto_reply_form, to_form(Email.change_auto_reply(auto_reply, %{})))
  end

  # Filter Events

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

  def handle_event("show_filter_modal", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case get_filter(id, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Filter not found")}

      filter ->
        {:noreply,
         socket
         |> assign(:show_modal, "filter")
         |> assign(:edit_item, filter)
         |> assign(:filter_form, build_filter_form(filter))}
    end
  end

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

  def handle_event("save_category_filters", %{"mailbox" => params}, socket) do
    user_id = socket.assigns.current_user.id
    mailbox = Email.get_user_mailbox(user_id) || socket.assigns.mailbox

    attrs = %{
      "auto_reply_enabled" => truthy_form_value?(params["auto_reply_enabled"]),
      "spam_filter_enabled" => truthy_form_value?(params["spam_filter_enabled"]),
      "digest_filter_enabled" => truthy_form_value?(params["digest_filter_enabled"]),
      "ledger_filter_enabled" => truthy_form_value?(params["ledger_filter_enabled"])
    }

    case Email.update_mailbox_category_filters(mailbox, attrs) do
      {:ok, mailbox} ->
        Elektrine.Email.Cached.invalidate_message_caches(mailbox.id, user_id)

        {:noreply,
         socket
         |> put_flash(:info, "Mailbox filters updated")
         |> assign(:mailbox, mailbox)
         |> assign(
           :mailbox_filter_form,
           to_form(Email.change_mailbox_category_filters(mailbox), as: :mailbox)
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update inbox category filters")
         |> assign(:mailbox_filter_form, to_form(changeset, as: :mailbox))}
    end
  end

  def handle_event("toggle_filter", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case get_filter(id, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Filter not found")}

      filter ->
        {:ok, _} = Email.toggle_filter(filter)

        {:noreply, assign(socket, :filters, Email.list_filters(user_id))}
    end
  end

  def handle_event("delete_filter", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case get_filter(id, user_id) do
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

  # Private helpers

  defp get_filter(id, user_id) do
    case parse_positive_id(id) do
      {:ok, id} -> Email.get_filter(id, user_id)
      :error -> nil
    end
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

  defp truthy_form_value?(values) when is_list(values),
    do: Enum.any?(values, &truthy_form_value?/1)

  defp truthy_form_value?(value), do: value in [true, "true", "on", 1, "1"]

  defp build_conditions_from_params(params) do
    rule_value = params["rule_value"] || ""

    rules =
      if String.trim(to_string(rule_value)) == "" do
        []
      else
        [
          %{
            "field" => params["rule_field"] || "from",
            "operator" => params["rule_operator"] || "contains",
            "value" => rule_value
          }
        ]
      end

    %{
      "match_type" => params["match_type"] || "all",
      "rules" => rules
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

  defp describe_filter(filter) do
    rules = get_in(filter.conditions, ["rules"]) || []
    actions = filter.actions || %{}

    rule_desc =
      if rules == [] do
        "all messages"
      else
        rules
        |> Enum.map(fn rule ->
          "#{rule["field"]} #{rule["operator"]} '#{rule["value"]}'"
        end)
        |> Enum.map_join(", ", & &1)
      end

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
      |> case do
        "" -> "do nothing"
        description -> description
      end

    "If #{rule_desc} then #{action_desc}"
  end

  # Render functions

  def render_filters_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xl font-semibold">Email Filters</h2>
        <p class="mt-1 text-base-content/70">
          Automatically organize incoming emails based on rules.
        </p>
      </div>
      
    <!-- Category Filters -->
      <.form
        for={@mailbox_filter_form}
        phx-submit="save_category_filters"
        class="card space-y-4 mb-8 p-5"
      >
        <div>
          <h3 class="font-semibold text-lg mb-1">Mailbox Filters</h3>
          <p class="text-sm text-base-content/60">
            Control automatic spam-folder delivery, auto-replies, and optional inbox category views.
          </p>
        </div>

        <div class="grid gap-3 sm:grid-cols-2">
          <label class="flex items-start justify-between gap-3 rounded-lg bg-base-200/55 p-3">
            <input type="hidden" name="mailbox[auto_reply_enabled]" value="false" />
            <span>
              <span class="block font-medium">Auto-Reply</span>
              <span class="text-sm text-base-content/60">
                Allow this mailbox to send automatic replies when your auto-reply is active.
              </span>
            </span>
            <input
              type="checkbox"
              name="mailbox[auto_reply_enabled]"
              value="true"
              checked={@mailbox_filter_form[:auto_reply_enabled].value in [true, "true"]}
              class="toggle toggle-secondary"
            />
          </label>

          <label class="flex items-start justify-between gap-3 rounded-lg bg-base-200/55 p-3">
            <input type="hidden" name="mailbox[spam_filter_enabled]" value="false" />
            <span>
              <span class="block font-medium">Spam Folder</span>
              <span class="text-sm text-base-content/60">
                Deliver messages flagged by spam scoring into Spam instead of Inbox.
              </span>
            </span>
            <input
              type="checkbox"
              name="mailbox[spam_filter_enabled]"
              value="true"
              checked={@mailbox_filter_form[:spam_filter_enabled].value in [true, "true"]}
              class="toggle toggle-secondary"
            />
          </label>

          <label class="flex items-start justify-between gap-3 rounded-lg bg-base-200/55 p-3">
            <input type="hidden" name="mailbox[digest_filter_enabled]" value="false" />
            <span>
              <span class="block font-medium">Digest</span>
              <span class="text-sm text-base-content/60">
                Newsletters and bulk mail get their own inbox filter.
              </span>
            </span>
            <input
              type="checkbox"
              name="mailbox[digest_filter_enabled]"
              value="true"
              checked={@mailbox_filter_form[:digest_filter_enabled].value in [true, "true"]}
              class="toggle toggle-secondary"
            />
          </label>

          <label class="flex items-start justify-between gap-3 rounded-lg bg-base-200/55 p-3">
            <input type="hidden" name="mailbox[ledger_filter_enabled]" value="false" />
            <span>
              <span class="block font-medium">Ledger</span>
              <span class="text-sm text-base-content/60">
                Receipts, invoices, and transaction mail get their own inbox filter.
              </span>
            </span>
            <input
              type="checkbox"
              name="mailbox[ledger_filter_enabled]"
              value="true"
              checked={@mailbox_filter_form[:ledger_filter_enabled].value in [true, "true"]}
              class="toggle toggle-secondary"
            />
          </label>
        </div>

        <div class="flex justify-end">
          <button type="submit" class="btn btn-secondary btn-sm">Save Mailbox Filters</button>
        </div>
      </.form>
      
    <!-- List -->
      <div class="mb-3 flex items-center justify-between gap-3">
        <h3 class="font-semibold text-lg">Custom Rules</h3>
        <button phx-click="show_filter_modal" phx-value-id="new" class="btn btn-secondary btn-sm">
          Create Filter
        </button>
      </div>

      <div class="space-y-3">
        <%= for filter <- @filters do %>
          <div class="card p-4">
            <div class="flex items-start justify-between gap-4">
              <div class="flex min-w-0 flex-1 items-start gap-4">
                <input
                  type="checkbox"
                  checked={filter.enabled}
                  phx-click="toggle_filter"
                  phx-value-id={filter.id}
                  class="checkbox checkbox-sm mt-1"
                />
                <div class="min-w-0 flex-1">
                  <div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:gap-3">
                    <span class="font-semibold text-lg">{filter.name}</span>
                    <%= if !filter.enabled do %>
                      <span class="badge badge-sm badge-warning gap-1">
                        <.icon name="hero-pause" class="w-3 h-3" /> Disabled
                      </span>
                    <% end %>
                  </div>
                  <div class="mt-1 text-sm text-base-content/50">
                    {describe_filter(filter)}
                  </div>
                </div>
              </div>
              <div class="flex shrink-0 gap-2">
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
          </div>
        <% end %>
        <%= if Enum.empty?(@filters) do %>
          <div class="text-center py-12 bg-base-200/30 rounded-lg border border-dashed border-base-content/20">
            <.icon name="hero-funnel" class="w-12 h-12 mx-auto text-base-content/30 mb-3" />
            <p class="text-base-content/50">No filters created yet</p>
            <p class="text-sm text-base-content/40 mt-1">Create your first custom rule above</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def render_autoreply_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xl font-semibold">Auto-Reply</h2>
        <p class="mt-1 text-base-content/70">
          Send automatic replies when you are unavailable.
        </p>
      </div>

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
                class="checkbox checkbox-sm checkbox-secondary"
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
                class="checkbox checkbox-sm checkbox-secondary"
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
                class="checkbox checkbox-sm checkbox-secondary"
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
          <button type="submit" class="btn btn-secondary">
            <.icon name="hero-check" class="h-4 w-4" /> Save Settings
          </button>
        </div>
      </.form>
    </div>
    """
  end

  def render_filter_modal(assigns) do
    ~H"""
    <!-- Header -->
    <div class="flex items-center justify-between mb-6">
      <div class="flex items-center gap-3">
        <div class="p-2 bg-secondary/10 rounded-lg">
          <.icon name="hero-funnel" class="h-5 w-5 text-secondary" />
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

      <div class="divider text-xs text-base-content/50 my-2">CONDITIONS (OPTIONAL)</div>
      
    <!-- Conditions Section -->
      <div class="bg-base-200/50 rounded-lg p-4 space-y-4">
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-medium">Match Type</span>
          </label>
          <div class="select select-bordered w-full">
            <select name="match_type">
              <option value="all" selected={@filter_form[:match_type].value == "all"}>
                All conditions must match
              </option>
              <option value="any" selected={@filter_form[:match_type].value == "any"}>
                Any condition can match
              </option>
            </select>
          </div>
        </div>

        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-medium">Condition</span>
          </label>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
            <div class="select select-bordered">
              <select name="rule_field">
                <option value="from" selected={@filter_form[:rule_field].value == "from"}>
                  From
                </option>
                <option value="to" selected={@filter_form[:rule_field].value == "to"}>
                  To
                </option>
                <option
                  value="subject"
                  selected={@filter_form[:rule_field].value == "subject"}
                >
                  Subject
                </option>
                <option value="body" selected={@filter_form[:rule_field].value == "body"}>
                  Body
                </option>
              </select>
            </div>
            <div class="select select-bordered">
              <select name="rule_operator">
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
                <option
                  value="equals"
                  selected={@filter_form[:rule_operator].value == "equals"}
                >
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
            </div>
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

      <div class="divider text-xs text-base-content/50 my-2">ACTIONS (OPTIONAL)</div>
      
    <!-- Actions Section -->
      <div class="bg-base-200/50 rounded-lg p-4">
        <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
          <label class="flex items-center gap-2 cursor-pointer p-2 rounded hover:bg-base-300/50 transition-colors">
            <input
              type="checkbox"
              name="action_mark_read"
              value="true"
              checked={@filter_form[:action_mark_read].value == "true"}
              class="checkbox checkbox-sm checkbox-secondary"
            />
            <span class="text-sm">Mark as read</span>
          </label>
          <label class="flex items-center gap-2 cursor-pointer p-2 rounded hover:bg-base-300/50 transition-colors">
            <input
              type="checkbox"
              name="action_archive"
              value="true"
              checked={@filter_form[:action_archive].value == "true"}
              class="checkbox checkbox-sm checkbox-secondary"
            />
            <span class="text-sm">Archive</span>
          </label>
          <label class="flex items-center gap-2 cursor-pointer p-2 rounded hover:bg-base-300/50 transition-colors">
            <input
              type="checkbox"
              name="action_star"
              value="true"
              checked={@filter_form[:action_star].value == "true"}
              class="checkbox checkbox-sm checkbox-secondary"
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
            <div class="select select-bordered select-sm flex-1">
              <select name="action_priority">
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
            class="toggle toggle-secondary toggle-sm"
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
        <button type="submit" class="btn btn-secondary">
          <.icon name="hero-check" class="h-4 w-4" /> Save Filter
        </button>
      </div>
    </form>
    """
  end
end
