defmodule ElektrineEmailWeb.EmailLive.Settings do
  @moduledoc """
  Email settings LiveView.

  Thin coordinator: mount/params/info plumbing and the page chrome live here,
  while each settings domain (events, tab data loading, and tab render
  functions) lives in a module under `ElektrineEmailWeb.EmailLive.Settings.*`.
  """

  use ElektrineEmailWeb, :live_view
  import ElektrineEmailWeb.EmailLive.EmailHelpers
  import ElektrineEmailWeb.Components.Email.Sidebar
  import ElektrineEmailWeb.Components.Platform.ElektrineNav

  import ElektrineEmailWeb.EmailLive.Settings.SenderSettings,
    only: [render_blocked_tab: 1, render_safe_tab: 1]

  import ElektrineEmailWeb.EmailLive.Settings.FilterSettings,
    only: [render_filters_tab: 1, render_autoreply_tab: 1, render_filter_modal: 1]

  import ElektrineEmailWeb.EmailLive.Settings.ContentSettings,
    only: [
      render_templates_tab: 1,
      render_folders_tab: 1,
      render_labels_tab: 1,
      render_export_tab: 1,
      render_template_modal: 1
    ]

  import ElektrineEmailWeb.EmailLive.Settings.DomainSettings, only: [render_aliases_tab: 1]

  alias Elektrine.Email

  alias ElektrineEmailWeb.EmailLive.Settings.{
    ContentSettings,
    DomainSettings,
    FilterSettings,
    SenderSettings
  }

  @sender_events ~w(block_sender unblock_sender add_safe_sender remove_safe_sender)

  @filter_events ~w(show_filter_modal save_filter save_category_filters toggle_filter
                    delete_filter save_auto_reply)

  @content_events ~w(show_template_modal save_template delete_template create_folder
                     delete_folder create_label delete_label start_export delete_export)

  @domain_events ~w(create_alias toggle_alias delete_alias create_custom_domain
                    verify_custom_domain sync_custom_domain_dkim delete_custom_domain
                    update_mailbox_forwarding)

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    if is_nil(user) do
      {:ok,
       socket
       |> put_flash(:error, "You must be logged in to access email settings")
       |> redirect(to: Elektrine.Paths.login_path())}
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

    unread_count = Email.unread_inbox_count(mailbox.id)

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
     |> assign(:mailbox_addresses, mailbox_addresses(mailbox, fresh_user))
     |> assign(:unread_count, unread_count)
     |> assign(:storage_info, storage_info)
     |> assign(:custom_folders, Email.list_custom_folders(user.id))
     |> assign(:current_folder_id, nil)
     |> assign(:active_tab, "aliases")
     |> assign(:show_modal, nil)
     |> assign(:edit_item, nil)
     |> assign(:domain_action_in_progress, nil)
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

  defp load_tab_data(socket, tab) when tab in ["blocked", "safe"],
    do: SenderSettings.load_tab_data(socket, tab)

  defp load_tab_data(socket, tab) when tab in ["filters", "autoreply"],
    do: FilterSettings.load_tab_data(socket, tab)

  defp load_tab_data(socket, tab) when tab in ["templates", "folders", "labels", "export"],
    do: ContentSettings.load_tab_data(socket, tab)

  defp load_tab_data(socket, "aliases" = tab),
    do: DomainSettings.load_tab_data(socket, tab)

  defp load_tab_data(socket, _tab), do: socket

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/email/settings?tab=#{tab}")}
  end

  def handle_event("show_keyboard_shortcuts", _params, socket) do
    {:noreply, push_event(socket, "show-keyboard-shortcuts", %{})}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, nil)
     |> assign(:edit_item, nil)}
  end

  def handle_event(event, params, socket) when event in @sender_events,
    do: SenderSettings.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @filter_events,
    do: FilterSettings.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @content_events,
    do: ContentSettings.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @domain_events,
    do: DomainSettings.handle_event(event, params, socket)

  @impl true
  def handle_async(:verify_custom_domain = name, result, socket),
    do: DomainSettings.handle_async(name, result, socket)

  def handle_async(:sync_custom_domain_dkim = name, result, socket),
    do: DomainSettings.handle_async(name, result, socket)

  # PubSub handlers
  @impl true
  def handle_info({:new_email, _message}, socket) do
    mailbox = socket.assigns.mailbox
    unread_count = Email.unread_inbox_count(mailbox.id)
    {:noreply, assign(socket, :unread_count, unread_count)}
  end

  def handle_info({:unread_count_updated, _new_count}, socket) do
    {:noreply, assign(socket, :unread_count, Email.unread_inbox_count(socket.assigns.mailbox.id))}
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
      <.elektrine_nav active_tab="email" current_user={@current_user} />

      <div class="email-sidebar-layout flex flex-col lg:flex-row items-start gap-4 lg:gap-3 min-h-[calc(100vh-10rem)] lg:min-h-[calc(100vh-12rem)]">
        <.sidebar
          current_page="settings"
          unread_count={@unread_count}
          mailbox={@mailbox}
          mailbox_addresses={@mailbox_addresses}
          storage_info={@storage_info}
          current_user={@current_user}
          custom_folders={@custom_folders}
          current_folder_id={@current_folder_id}
        />

        <div class="w-full flex-1 min-w-0 max-w-full overflow-visible">
          <div
            id="email-settings-card"
            class="card panel-card rounded-lg"
          >
            <div class="card-body p-3 sm:p-6">
              <!-- Header -->
              <div class="flex items-center space-x-2 sm:space-x-3 mb-4 sm:mb-6">
                <div class="p-1.5 sm:p-2 bg-secondary/10 rounded-lg">
                  <.icon name="hero-cog-6-tooth" class="h-5 w-5 sm:h-6 sm:w-6 text-secondary" />
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

  defp render_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box modal-surface max-w-2xl border border-purple-500/30 shadow-xl">
        <%= case @show_modal do %>
          <% "filter" -> %>
            {render_filter_modal(assigns)}
          <% "template" -> %>
            {render_template_modal(assigns)}
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
end
