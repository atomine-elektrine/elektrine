defmodule ElektrineEmailWeb.EmailLive.Settings.ContentSettings do
  @moduledoc """
  Template, folder, label, and export settings: event handlers, tab data
  loading, and per-tab render functions for
  `ElektrineEmailWeb.EmailLive.Settings`.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [put_flash: 3]
  import ElektrineWeb.CoreComponents
  import ElektrineEmailWeb.EmailLive.Settings.Helpers

  # Routes generation with the ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router,
    statics: ElektrineWeb.static_paths()

  alias Elektrine.Email
  alias Elektrine.Email.{Folder, Label, Template}

  # Tab data loading

  def load_tab_data(socket, "templates") do
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:templates, Email.list_templates(user_id))
    |> assign(:new_template, %Template{})
  end

  def load_tab_data(socket, "folders") do
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:folders, Email.list_custom_folders(user_id))
    |> assign(:new_folder, %Folder{})
  end

  def load_tab_data(socket, "labels") do
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:labels, Email.list_labels(user_id))
    |> assign(:new_label, %Label{})
  end

  def load_tab_data(socket, "export") do
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:exports, Email.list_exports(user_id))
  end

  # Template Events

  def handle_event("show_template_modal", %{"id" => "new"}, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, "template")
     |> assign(:edit_item, nil)
     |> assign(:template_form, to_form(%{"name" => "", "subject" => "", "body" => ""}))}
  end

  def handle_event("show_template_modal", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case get_template(id, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Template not found")}

      template ->
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
  end

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

  def handle_event("delete_template", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case get_template(id, user_id) do
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

  def handle_event("create_folder", %{"name" => name, "color" => color}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.create_custom_folder(%{name: name, color: color, user_id: user_id}) do
      {:ok, _} ->
        folders = Email.list_custom_folders(user_id)

        {:noreply,
         socket
         |> put_flash(:info, "Folder created successfully")
         |> assign(:folders, folders)
         |> assign(:custom_folders, folders)}

      {:error, :limit_reached} ->
        {:noreply, put_flash(socket, :error, "Maximum number of folders reached (25)")}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply, put_flash(socket, :error, "Failed to create folder: #{error}")}
    end
  end

  def handle_event("delete_folder", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case get_custom_folder(id, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Folder not found")}

      folder ->
        {:ok, _} = Email.delete_custom_folder(folder)
        folders = Email.list_custom_folders(user_id)

        {:noreply,
         socket
         |> put_flash(:info, "Folder deleted")
         |> assign(:folders, folders)
         |> assign(:custom_folders, folders)}
    end
  end

  # Label Events

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

  def handle_event("delete_label", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case get_label(id, user_id) do
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

  def handle_event("delete_export", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case get_export(id, user_id) do
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

  # Render functions

  defp get_template(id, user_id) do
    case parse_positive_id(id) do
      {:ok, id} -> Email.get_template(id, user_id)
      :error -> nil
    end
  end

  defp get_custom_folder(id, user_id) do
    case parse_positive_id(id) do
      {:ok, id} -> Email.get_custom_folder(id, user_id)
      :error -> nil
    end
  end

  defp get_label(id, user_id) do
    case parse_positive_id(id) do
      {:ok, id} -> Email.get_label(id, user_id)
      :error -> nil
    end
  end

  defp get_export(id, user_id) do
    case parse_positive_id(id) do
      {:ok, id} -> Email.get_export(id, user_id)
      :error -> nil
    end
  end

  def render_templates_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xl font-semibold">Email Templates</h2>
        <p class="mt-1 text-base-content/70">
          Save commonly used email templates for quick access.
        </p>
      </div>
      <div class="mb-4 flex justify-end">
        <button phx-click="show_template_modal" phx-value-id="new" class="btn btn-secondary">
          Create Template
        </button>
      </div>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for template <- @templates do %>
          <div class="flex items-center justify-between p-3 surface-subtle rounded-lg">
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
          <div class="text-center py-12 bg-base-200/30 rounded-lg border border-dashed border-base-content/20">
            <.icon name="hero-document-text" class="w-12 h-12 mx-auto text-base-content/30 mb-3" />
            <p class="text-base-content/50">No templates created yet</p>
            <p class="text-sm text-base-content/40 mt-1">Create your first template above</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def render_folders_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xl font-semibold">Custom Folders</h2>
        <p class="mt-1 text-base-content/70">
          Create custom folders to organize your emails.
        </p>
      </div>
      
    <!-- Add Form -->
      <form phx-submit="create_folder" class="flex gap-2 mb-6">
        <input
          type="text"
          name="name"
          placeholder="Folder name"
          class="input input-bordered flex-1"
          required
        />
        <div class="select select-bordered">
          <select name="color">
            <option value="#3b82f6">Blue</option>
            <option value="#22c55e">Green</option>
            <option value="#ef4444">Red</option>
            <option value="#f59e0b">Orange</option>
            <option value="#8a7cc2">Plum</option>
            <option value="#c7796b">Rose Clay</option>
            <option value="#6b7280">Gray</option>
          </select>
        </div>
        <button type="submit" class="btn btn-secondary">Create</button>
      </form>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for folder <- @folders do %>
          <div class="flex items-center justify-between p-3 surface-subtle rounded-lg">
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
          <div class="text-center py-12 bg-base-200/30 rounded-lg border border-dashed border-base-content/20">
            <.icon name="hero-folder" class="w-12 h-12 mx-auto text-base-content/30 mb-3" />
            <p class="text-base-content/50">No custom folders yet</p>
            <p class="text-sm text-base-content/40 mt-1">Create one above to organize your mail</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def render_labels_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xl font-semibold">Labels</h2>
        <p class="mt-1 text-base-content/70">
          Create labels to tag and categorize your emails.
        </p>
      </div>
      
    <!-- Add Form -->
      <form phx-submit="create_label" class="flex gap-2 mb-6">
        <input
          type="text"
          name="name"
          placeholder="Label name"
          class="input input-bordered flex-1"
          required
        />
        <div class="select select-bordered">
          <select name="color">
            <option value="#3b82f6">Blue</option>
            <option value="#22c55e">Green</option>
            <option value="#ef4444">Red</option>
            <option value="#f59e0b">Orange</option>
            <option value="#8a7cc2">Plum</option>
            <option value="#c7796b">Rose Clay</option>
            <option value="#6b7280">Gray</option>
          </select>
        </div>
        <button type="submit" class="btn btn-secondary">Create</button>
      </form>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for label <- @labels do %>
          <div class="flex items-center justify-between p-3 surface-subtle rounded-lg">
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
          <div class="text-center py-12 bg-base-200/30 rounded-lg border border-dashed border-base-content/20">
            <.icon name="hero-tag" class="w-12 h-12 mx-auto text-base-content/30 mb-3" />
            <p class="text-base-content/50">No labels created yet</p>
            <p class="text-sm text-base-content/40 mt-1">Create one above to tag your messages</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def render_export_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xl font-semibold">Export Emails</h2>
        <p class="mt-1 text-base-content/70">
          Download a backup of your emails.
        </p>
      </div>
      
    <!-- Export Options -->
      <div class="flex flex-wrap gap-2 mb-6">
        <button phx-click="start_export" phx-value-format="mbox" class="btn btn-secondary btn-sm">
          Export as MBOX
        </button>
        <button phx-click="start_export" phx-value-format="zip" class="btn btn-secondary btn-sm">
          Export as ZIP (EML files)
        </button>
      </div>
      
    <!-- Export History -->
      <h3 class="font-semibold mb-2">Export History</h3>
      <div class="space-y-2">
        <%= for export <- @exports do %>
          <div class="flex items-center justify-between p-3 surface-subtle rounded-lg">
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
                data-confirm="Are you sure you want to delete this export?"
              >
                Delete
              </button>
            </div>
          </div>
        <% end %>
        <%= if Enum.empty?(@exports) do %>
          <div class="text-center py-12 bg-base-200/30 rounded-lg border border-dashed border-base-content/20">
            <.icon name="hero-arrow-down-tray" class="w-12 h-12 mx-auto text-base-content/30 mb-3" />
            <p class="text-base-content/50">No exports yet</p>
            <p class="text-sm text-base-content/40 mt-1">
              Start an export above to download a backup
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def render_template_modal(assigns) do
    ~H"""
    <!-- Header -->
    <div class="flex items-center justify-between mb-6">
      <div>
        <h3 class="text-lg font-semibold tracking-tight">
          {if @edit_item, do: "Edit Template", else: "Create Template"}
        </h3>
        <p class="text-sm text-base-content/60">Save commonly used email content</p>
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
        <button type="submit" class="btn btn-secondary">
          <.icon name="hero-check" class="h-4 w-4" /> Save Template
        </button>
      </div>
    </form>
    """
  end

  defp status_color("completed"), do: "success"
  defp status_color("processing"), do: "info"
  defp status_color("failed"), do: "error"
  defp status_color(_), do: "ghost"
end
