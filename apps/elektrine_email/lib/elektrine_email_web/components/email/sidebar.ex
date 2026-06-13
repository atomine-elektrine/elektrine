defmodule ElektrineEmailWeb.Components.Email.Sidebar do
  @moduledoc """
  Sidebar function component shared by the email LiveViews.
  """
  use Phoenix.Component
  import ElektrineWeb.CoreComponents

  alias ElektrineEmailWeb.EmailLive.EmailHelpers

  # Translation
  use Gettext, backend: ElektrineWeb.Gettext

  # Routes generation with the ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router,
    statics: ElektrineWeb.static_paths()

  attr :mailbox, :map, required: true
  attr :storage_info, :map, required: false
  attr :unread_count, :integer, required: true
  attr :current_page, :string, required: true
  attr :current_user, :map, required: true
  attr :mailbox_addresses, :list, default: nil
  attr :custom_folders, :list, default: []
  attr :current_folder_id, :integer, default: nil
  attr :class, :any, default: nil

  def sidebar(assigns) do
    # Use storage_info from assigns (updated via PubSub broadcasts)
    # Don't fetch from DB on every render - that's inefficient and ignores real-time updates
    # Ensure custom_folders has a default value
    assigns = assign_new(assigns, :custom_folders, fn -> [] end)
    assigns = assign_new(assigns, :current_folder_id, fn -> nil end)

    assigns =
      assign_new(assigns, :mailbox_addresses, fn ->
        EmailHelpers.default_sidebar_mailbox_addresses(assigns.mailbox)
      end)

    assigns =
      assign(
        assigns,
        :mailbox_addresses,
        EmailHelpers.normalize_sidebar_mailbox_addresses(
          assigns.mailbox,
          assigns.mailbox_addresses
        )
      )

    ~H"""
    <!-- Sidebar -->
    <.sticky_sidebar class={["w-full lg:w-72 xl:w-80 flex-shrink-0", @class]}>
      <div class="lg:hidden">
        <div
          id={"mobile-email-sidebar-card-#{@mailbox.id}"}
          class="card panel-card rounded-lg"
        >
          <div class="card-body p-4 space-y-4">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0 flex-1">
                <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/50">
                  {gettext("Mailbox")}
                </p>
                <div class="mt-2 space-y-1.5">
                  <%= for address <- @mailbox_addresses do %>
                    <% primary_address = String.downcase(address) == String.downcase(@mailbox.email) %>
                    <div class="flex items-center gap-2">
                      <p
                        class={[
                          "font-mono truncate flex-1",
                          if(primary_address,
                            do: "text-sm text-base-content/75",
                            else: "text-xs text-base-content/55"
                          )
                        ]}
                        title={address}
                      >
                        {address}
                      </p>
                      <button
                        id={"copy-email-mobile-#{@mailbox.id}-#{:erlang.phash2(address)}"}
                        type="button"
                        phx-hook="CopyEmail"
                        data-email={address}
                        class="btn btn-ghost btn-xs flex-shrink-0"
                        title={gettext("Copy to clipboard")}
                      >
                        <.icon name="hero-clipboard-document" class="w-3 h-3" />
                      </button>
                    </div>
                  <% end %>
                </div>
              </div>

              <%= if @unread_count > 0 do %>
                <div class="badge badge-secondary badge-sm whitespace-nowrap">
                  {gettext("%{count} unread", count: @unread_count)}
                </div>
              <% end %>
            </div>

            <%= if @storage_info do %>
              <div class="rounded-lg border border-base-300/60 bg-base-100/60 p-3">
                <div class="flex items-center justify-between gap-2 text-xs mb-2">
                  <span class="font-medium uppercase tracking-wide text-base-content/60">
                    {gettext("Storage")}
                  </span>
                  <span class="text-base-content/70">
                    {@storage_info.used_formatted} / {@storage_info.limit_formatted}
                  </span>
                </div>

                <div class="w-full h-2 bg-base-300/50 rounded-full overflow-hidden shadow-inner">
                  <div
                    class={
                      cond do
                        @storage_info.over_limit ->
                          "h-full bg-gradient-to-r from-red-700 to-red-800 transition-all duration-300"

                        @storage_info.percentage > 0.8 ->
                          "h-full bg-gradient-to-r from-warning to-warning transition-all duration-300"

                        true ->
                          "h-full bg-gradient-to-r from-secondary to-secondary transition-all duration-300"
                      end
                    }
                    style={"width: #{min(@storage_info.percentage * 100, 100)}%"}
                  />
                </div>
              </div>
            <% end %>

            <div class="flex items-center gap-2">
              <.link
                navigate={~p"/email/compose?return_to=#{@current_page}"}
                class="btn btn-secondary btn-sm flex-1 gap-2"
              >
                <.icon name="hero-pencil-square" class="h-4 w-4" /> {gettext("Compose")}
              </.link>
              <button
                class="btn btn-ghost btn-sm flex-shrink-0"
                phx-click="show_keyboard_shortcuts"
                title={gettext("Keyboard shortcuts (Shift + /)")}
              >
                <.icon name="hero-command-line" class="h-4 w-4" />
              </button>
            </div>

            <div class="space-y-3">
              <div class="overflow-x-auto pb-1">
                <div class="flex min-w-max items-center gap-2">
                  <a
                    href={Elektrine.Paths.email_index_path(tab: "inbox")}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "inbox",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-inbox" class="h-4 w-4" />
                    {gettext("Inbox")}
                    <%= if @unread_count > 0 do %>
                      <span class="badge badge-secondary badge-xs">{@unread_count}</span>
                    <% end %>
                  </a>
                  <a
                    href={Elektrine.Paths.email_index_path(tab: "sent")}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "sent",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-paper-airplane" class="h-4 w-4" />
                    {gettext("Sent")}
                  </a>
                  <a
                    href={Elektrine.Paths.email_index_path(tab: "drafts")}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "drafts",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-document" class="h-4 w-4" />
                    {gettext("Drafts")}
                  </a>
                  <a
                    href={Elektrine.Paths.email_index_path(tab: "search")}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "search",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-magnifying-glass" class="h-4 w-4" />
                    {gettext("Search")}
                  </a>
                  <a
                    href={Elektrine.Paths.email_index_path(tab: "archive")}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "archive",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-archive-box" class="h-4 w-4" />
                    {gettext("Archive")}
                  </a>
                  <a
                    href={Elektrine.Paths.email_index_path(tab: "spam")}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "spam",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
                    {gettext("Spam")}
                  </a>
                  <a
                    href={Elektrine.Paths.email_index_path(tab: "trash")}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "trash",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-trash" class="h-4 w-4" />
                    {gettext("Trash")}
                  </a>
                  <a
                    href={Elektrine.Paths.email_index_path(tab: "contacts")}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "contacts",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-user-group" class="h-4 w-4" />
                    {gettext("Contacts")}
                  </a>
                  <a
                    href={Elektrine.Paths.email_index_path(tab: "calendar")}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "calendar",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-calendar" class="h-4 w-4" />
                    {gettext("Calendar")}
                  </a>
                  <.link
                    navigate={~p"/email/settings"}
                    class={[
                      "btn btn-sm rounded-full whitespace-nowrap",
                      if(@current_page == "settings",
                        do: "btn-secondary",
                        else: "btn-ghost bg-base-100/60"
                      )
                    ]}
                  >
                    <.icon name="hero-cog-6-tooth" class="h-4 w-4" />
                    {gettext("Settings")}
                  </.link>
                </div>
              </div>

              <%= if length(@custom_folders) > 0 do %>
                <div class="space-y-2">
                  <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/50">
                    {gettext("Folders")}
                  </p>
                  <div class="overflow-x-auto pb-1">
                    <div class="flex min-w-max items-center gap-2">
                      <%= for folder <- @custom_folders do %>
                        <% is_active = @current_page == "folder" && @current_folder_id == folder.id %>
                        <a
                          href={Elektrine.Paths.email_index_path(tab: "folder", folder_id: folder.id)}
                          data-phx-link="patch"
                          data-phx-link-state="push"
                          class={[
                            "btn btn-sm rounded-full whitespace-nowrap",
                            if(is_active, do: "btn-secondary", else: "btn-ghost bg-base-100/60")
                          ]}
                        >
                          <span
                            class="w-2.5 h-2.5 rounded-full flex-shrink-0"
                            style={"background-color: #{folder.color || "#3b82f6"}"}
                          />
                          <.icon name="hero-folder" class="h-4 w-4" />
                          {folder.name}
                        </a>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <div class="email-sidebar-scroll hidden lg:block pr-1">
        <!-- Mailbox Info Card -->
        <div
          id={"mailbox-info-card-#{@mailbox.id}"}
          class="card panel-card mb-6 rounded-lg"
        >
          <div class="card-body p-6">
            <div class="flex-1 min-w-0">
              <h2 class="font-bold text-lg">{gettext("Your Mailbox")}</h2>
              <div class="space-y-1">
                <%= for address <- @mailbox_addresses do %>
                  <% primary_address = String.downcase(address) == String.downcase(@mailbox.email) %>
                  <div class="flex items-center gap-2">
                    <p
                      class={[
                        "font-mono truncate flex-1",
                        if(primary_address,
                          do: "text-sm text-base-content/70",
                          else: "text-xs text-base-content/50"
                        )
                      ]}
                      title={address}
                    >
                      {address}
                    </p>
                    <button
                      id={"copy-email-alternate-#{@mailbox.id}-#{:erlang.phash2(address)}"}
                      type="button"
                      phx-hook="CopyEmail"
                      data-email={address}
                      class="btn btn-ghost btn-xs flex-shrink-0"
                      title={gettext("Copy to clipboard")}
                    >
                      <.icon name="hero-clipboard-document" class="w-3 h-3" />
                    </button>
                  </div>
                <% end %>
                
    <!-- Storage Usage Display - Hidden on smaller screens -->
                <%= if @storage_info do %>
                  <div class="hidden xl:block mt-3 pt-3 border-t border-base-300/50">
                    <div class="flex items-center justify-between text-xs text-base-content/70 mb-1">
                      <span class="font-medium">{gettext("Storage Used")}</span>
                      <span class={
                        cond do
                          @storage_info.over_limit -> "text-red-800 font-semibold"
                          @storage_info.percentage > 0.8 -> "text-warning font-medium"
                          true -> "text-base-content/60"
                        end
                      }>
                        {@storage_info.used_formatted} / {@storage_info.limit_formatted}
                      </span>
                    </div>

                    <div class="flex items-center space-x-3">
                      <div class="flex-1 min-w-0">
                        <div class="w-full h-2 bg-base-300/50 rounded-full overflow-hidden shadow-inner">
                          <div
                            class={
                              cond do
                                @storage_info.over_limit ->
                                  "h-full bg-gradient-to-r from-red-700 to-red-800 transition-all duration-300"

                                @storage_info.percentage > 0.8 ->
                                  "h-full bg-gradient-to-r from-warning to-warning transition-all duration-300"

                                true ->
                                  "h-full bg-gradient-to-r from-secondary to-secondary transition-all duration-300"
                              end
                            }
                            style={"width: #{min(@storage_info.percentage * 100, 100)}%"}
                          />
                        </div>
                      </div>
                      <span class={
                        cond do
                          @storage_info.over_limit -> "text-red-800 font-semibold text-xs"
                          @storage_info.percentage > 0.8 -> "text-warning font-medium text-xs"
                          true -> "text-base-content/60 text-xs"
                        end
                      }>
                        {Float.round(@storage_info.percentage * 100, 1)}%
                      </span>
                    </div>

                    <%= cond do %>
                      <% @storage_info.over_limit -> %>
                        <div class="mt-2 text-xs text-red-800 font-medium flex items-center">
                          <.icon name="hero-exclamation-triangle" class="h-3 w-3 mr-1" />
                          {gettext("Storage limit exceeded")}
                        </div>
                      <% @storage_info.percentage > 0.8 -> %>
                        <div class="mt-2 text-xs text-warning font-medium flex items-center">
                          <.icon name="hero-exclamation-triangle" class="h-3 w-3 mr-1" />
                          {gettext("Storage nearly full")}
                        </div>
                      <% true -> %>
                        <!-- No warning needed -->
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Navigation Menu -->
        <div
          id={"nav-menu-card-#{@mailbox.id}"}
          class="card panel-card rounded-lg"
        >
          <div class="card-body p-3">
            <ul class="menu menu-lg rounded-box w-full">
              <li>
                <a
                  href={Elektrine.Paths.email_index_path(tab: "inbox")}
                  data-phx-link="patch"
                  data-phx-link-state="push"
                  class={
                    if(@current_page == "inbox",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                    )
                  }
                >
                  <.icon name="hero-inbox" class="h-5 w-5" /> {gettext("Inbox")}
                  <%= if @unread_count > 0 do %>
                    <div class="badge badge-sm badge-secondary animate-pulse">
                      {@unread_count}
                    </div>
                  <% end %>
                </a>
              </li>
              <li>
                <a
                  href={Elektrine.Paths.email_index_path(tab: "sent")}
                  data-phx-link="patch"
                  data-phx-link-state="push"
                  class={
                    if(@current_page == "sent",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                    )
                  }
                >
                  <.icon name="hero-paper-airplane" class="h-5 w-5" /> {gettext("Sent")}
                </a>
              </li>
              <li>
                <a
                  href={Elektrine.Paths.email_index_path(tab: "drafts")}
                  data-phx-link="patch"
                  data-phx-link-state="push"
                  class={
                    if(@current_page == "drafts",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                    )
                  }
                >
                  <.icon name="hero-document" class="h-5 w-5" /> {gettext("Drafts")}
                </a>
              </li>
              <li>
                <a
                  href={Elektrine.Paths.email_index_path(tab: "search")}
                  data-phx-link="patch"
                  data-phx-link-state="push"
                  class={
                    if(@current_page == "search",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                    )
                  }
                >
                  <.icon name="hero-magnifying-glass" class="h-5 w-5" /> {gettext("Search")}
                </a>
              </li>
              <li>
                <a
                  href={Elektrine.Paths.email_index_path(tab: "spam")}
                  data-phx-link="patch"
                  data-phx-link-state="push"
                  class={
                    if(@current_page == "spam",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                    )
                  }
                >
                  <.icon name="hero-exclamation-triangle" class="h-5 w-5" /> {gettext("Spam")}
                </a>
              </li>
              <li>
                <a
                  href={Elektrine.Paths.email_index_path(tab: "trash")}
                  data-phx-link="patch"
                  data-phx-link-state="push"
                  class={
                    if(@current_page == "trash",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                    )
                  }
                >
                  <.icon name="hero-trash" class="h-5 w-5" /> {gettext("Trash")}
                </a>
              </li>
              <li>
                <a
                  href={Elektrine.Paths.email_index_path(tab: "archive")}
                  data-phx-link="patch"
                  data-phx-link-state="push"
                  class={
                    if(@current_page == "archive",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                    )
                  }
                >
                  <.icon name="hero-archive-box" class="h-5 w-5" /> {gettext("Archive")}
                </a>
              </li>

              <li>
                <a
                  href={Elektrine.Paths.email_index_path(tab: "contacts")}
                  data-phx-link="patch"
                  data-phx-link-state="push"
                  class={
                    if(@current_page == "contacts",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                    )
                  }
                >
                  <.icon name="hero-user-group" class="h-5 w-5" /> {gettext("Contacts")}
                </a>
              </li>
              <li>
                <a
                  href={Elektrine.Paths.email_index_path(tab: "calendar")}
                  data-phx-link="patch"
                  data-phx-link-state="push"
                  class={
                    if(@current_page == "calendar",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                    )
                  }
                >
                  <.icon name="hero-calendar" class="h-5 w-5" /> {gettext("Calendar")}
                </a>
              </li>
              <li>
                <.link
                  navigate={~p"/email/settings"}
                  class={
                    if @current_page == "settings",
                      do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                      else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                  }
                >
                  <.icon name="hero-cog-6-tooth" class="h-5 w-5" /> {gettext("Settings")}
                </.link>
              </li>
              
    <!-- Custom Folders -->
              <%= if length(@custom_folders) > 0 do %>
                <li class="menu-title pt-4 pb-1">
                  <span class="text-xs uppercase tracking-wide text-base-content/50">
                    {gettext("Folders")}
                  </span>
                </li>
                <%= for folder <- @custom_folders do %>
                  <% is_active = @current_page == "folder" && @current_folder_id == folder.id %>
                  <li>
                    <a
                      href={Elektrine.Paths.email_index_path(tab: "folder", folder_id: folder.id)}
                      data-phx-link="patch"
                      data-phx-link-state="push"
                      class={
                        if(is_active,
                          do: "bg-secondary/10 text-secondary font-semibold rounded-lg",
                          else: "text-base-content hover:bg-secondary/5 hover:text-secondary"
                        )
                      }
                    >
                      <div class="flex items-center gap-2">
                        <span
                          class="w-2.5 h-2.5 rounded-full flex-shrink-0"
                          style={"background-color: #{folder.color || "#3b82f6"}"}
                        />
                        <.icon
                          name="hero-folder"
                          class={["h-5 w-5", !is_active && "text-base-content/70"]}
                        />
                      </div>
                      <span class="truncate">{folder.name}</span>
                    </a>
                  </li>
                <% end %>
              <% end %>
            </ul>
            
    <!-- Compose Button - Separate from menu -->
            <div class="mt-4">
              <.link
                navigate={~p"/email/compose?return_to=#{@current_page}"}
                class="btn btn-secondary w-full gap-2 flex items-center justify-center"
              >
                <.icon name="hero-pencil-square" class="h-5 w-5" /> {gettext("Compose")}
              </.link>
            </div>
            
    <!-- Keyboard Shortcuts Button -->
            <div class="mt-2">
              <button
                class="btn btn-ghost btn-sm w-full gap-2 flex items-center justify-center text-base-content/70 hover:text-base-content"
                phx-click="show_keyboard_shortcuts"
                title={gettext("Keyboard shortcuts (Shift + /)")}
              >
                <.icon name="hero-command-line" class="h-4 w-4" /> {gettext("Shortcuts")}
                <kbd class="kbd kbd-xs ml-1">?</kbd>
              </button>
            </div>
          </div>
        </div>
      </div>
    </.sticky_sidebar>
    """
  end
end
