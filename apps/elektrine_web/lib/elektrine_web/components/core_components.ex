defmodule ElektrineWeb.CoreComponents do
  @moduledoc """
  Provides core UI components through re-exports from organized submodules.

  This module serves as a central point for importing common components used throughout
  the application. All components have been organized into logical submodules under:

  - `ElektrineWeb.Components.UI.*` - User interface components (modal, button, form, table, icon)
  - `ElektrineWeb.Components.Layout.*` - Layout components (header, navigation, announcement)
  - `ElektrineWeb.Components.Datetime.*` - Datetime formatting components (local_time)
  - `ElektrineWeb.Components.Email.*` - Email processing and display utilities

  You can import this module with `use Phoenix.Component` to get access to all components,
  or import specific submodules for more granular control.

  ## Migration from monolithic to modular

  This module maintains backward compatibility by delegating all function calls to their
  new locations in organized submodules. This allows existing code to continue working
  without changes while providing a cleaner, more maintainable structure.

  ## Usage

  The default components use Tailwind CSS and DaisyUI for styling.
  Icons are provided by [heroicons](https://heroicons.com).
  """
  use Phoenix.Component
  use Gettext, backend: ElektrineWeb.Gettext
  alias Phoenix.LiveView.JS

  # UI Components
  alias ElektrineWeb.Components.UI.ActionToolbar
  alias ElektrineWeb.Components.UI.Badge
  alias ElektrineWeb.Components.UI.BrandIcon
  alias ElektrineWeb.Components.UI.Button
  alias ElektrineWeb.Components.UI.Card
  alias ElektrineWeb.Components.UI.Dropdown
  alias ElektrineWeb.Components.UI.EmptyState
  alias ElektrineWeb.Components.UI.FloatingPanel
  alias ElektrineWeb.Components.UI.Form
  alias ElektrineWeb.Components.UI.Icon
  alias ElektrineWeb.Components.UI.Loading
  alias ElektrineWeb.Components.UI.Modal
  alias ElektrineWeb.Components.UI.PillSwitcher
  alias ElektrineWeb.Components.UI.SectionHeader
  alias ElektrineWeb.Components.UI.StatsRow
  alias ElektrineWeb.Components.UI.Table

  # Layout Components
  alias ElektrineWeb.Components.Layout.Announcement
  alias ElektrineWeb.Components.Layout.Header
  alias ElektrineWeb.Components.Layout.Navigation

  # Datetime Components
  alias ElektrineWeb.Components.Datetime.LocalTime

  alias Elektrine.Platform.Modules
  alias ElektrineWeb.Platform.Integrations

  # Modal component and helpers
  defdelegate modal(assigns), to: Modal
  defdelegate basic_modal(assigns), to: Modal
  defdelegate show(js \\ %Phoenix.LiveView.JS{}, selector), to: Modal
  defdelegate hide(js \\ %Phoenix.LiveView.JS{}, selector), to: Modal
  defdelegate show_modal(js \\ %Phoenix.LiveView.JS{}, id), to: Modal
  defdelegate hide_modal(js \\ %Phoenix.LiveView.JS{}, id), to: Modal

  # Button component
  defdelegate button(assigns), to: Button

  # Floating panel component
  defdelegate floating_panel(assigns), to: FloatingPanel

  # Reusable page UI primitives
  defdelegate section_header(assigns), to: SectionHeader
  defdelegate pill_switcher(assigns), to: PillSwitcher
  defdelegate stats_row(assigns), to: StatsRow
  defdelegate action_toolbar(assigns), to: ActionToolbar

  # Form components
  defdelegate simple_form(assigns), to: Form
  defdelegate input(assigns), to: Form
  defdelegate label(assigns), to: Form
  defdelegate error(assigns), to: Form
  defdelegate translate_error(error), to: Form
  defdelegate translate_errors(errors, field), to: Form

  # Table and list components
  defdelegate table(assigns), to: Table
  defdelegate list(assigns), to: Table

  # Icon component
  defdelegate icon(assigns), to: Icon

  # Card components
  defdelegate card(assigns), to: Card
  defdelegate stat_card(assigns), to: Card
  defdelegate info_card(assigns), to: Card

  # Dropdown components
  defdelegate dropdown(assigns), to: Dropdown
  defdelegate dropdown_item(assigns), to: Dropdown
  defdelegate dropdown_divider(assigns), to: Dropdown

  # Empty state component
  defdelegate empty_state(assigns), to: EmptyState

  # Badge components
  defdelegate badge(assigns), to: Badge
  defdelegate count_badge(assigns), to: Badge
  defdelegate status_badge(assigns), to: Badge

  # Loading components
  defdelegate spinner(assigns), to: Loading
  defdelegate skeleton(assigns), to: Loading
  defdelegate loading_overlay(assigns), to: Loading

  # Brand icon component
  defdelegate brand_icon(assigns), to: BrandIcon

  # Header component
  defdelegate header(assigns), to: Header

  # Navigation components
  defdelegate back(assigns), to: Navigation

  # Announcement components
  defdelegate announcement(assigns), to: Announcement
  defdelegate announcements(assigns), to: Announcement

  # Datetime components
  defdelegate local_time(assigns), to: LocalTime

  @doc """
  Renders a consistent shell for account/settings detail pages.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :sidebar_tab, :string, default: nil
  attr :sidebar_link, :string, default: nil
  attr :nav_tab, :string, default: "account"
  attr :current_user, :any, default: nil
  attr :max_width, :string, default: nil
  attr :class, :string, default: nil
  slot :sidebar
  slot :inner_block, required: true

  def account_page(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl px-4 pb-2 sm:px-6 lg:px-8">
      <ElektrineWeb.Components.Platform.ENav.e_nav
        active_tab={@nav_tab}
        current_user={@current_user}
        class="mb-6 sm:mb-8"
      />

      <div class="mb-6 sm:mb-8">
        <h1 class="text-2xl sm:text-3xl font-bold text-base-content">
          {gettext("Account Settings")}
        </h1>
        <p class="text-base-content/70 mt-2">
          {gettext("Manage your account preferences and security settings")}
        </p>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-4 lg:gap-8">
        <div class="lg:col-span-1">
          <%= if @sidebar != [] do %>
            {render_slot(@sidebar)}
          <% else %>
            <.account_settings_sidebar
              :if={@sidebar_tab || @sidebar_link}
              selected_tab={@sidebar_tab}
              selected_link={@sidebar_link}
            />
          <% end %>
        </div>
        <section class={["w-full space-y-6 sm:space-y-8 lg:col-span-3", @max_width, @class]}>
          <header class="space-y-3">
            <h2 class="text-2xl font-bold text-base-content sm:text-3xl">{@title}</h2>
            <p :if={@subtitle} class="text-base-content/70">{@subtitle}</p>
          </header>
          {render_slot(@inner_block)}
        </section>
      </div>
    </div>
    """
  end

  attr :selected_tab, :string, default: nil
  attr :selected_link, :string, default: nil

  def account_settings_sidebar(assigns) do
    assigns = assign(assigns, :tabs, account_setting_tabs())

    ~H"""
    <div class="sticky top-24 self-start">
      <div class="card panel-card">
        <div class="card-body p-4">
          <h3 class="font-semibold text-sm mb-4">{gettext("Settings")}</h3>
          <ul class="menu menu-compact w-full p-0 space-y-1">
            <%= for {tab_id, tab_icon, tab_tone} <- @tabs do %>
              <li>
                <.link
                  navigate={"/account?tab=#{tab_id}"}
                  class={account_setting_link_class(@selected_tab, tab_id, tab_tone)}
                >
                  <.icon name={tab_icon} class="w-4 h-4" /> {account_setting_label(tab_id)}
                </.link>
              </li>
            <% end %>
          </ul>

          <div class="divider my-4"></div>

          <div class="space-y-2">
            <.link
              navigate="/account/profile/edit"
              class={account_setting_secondary_link_class(@selected_link, "profile")}
            >
              <.icon name="hero-user-circle" class="w-4 h-4" /> {gettext("E Profile")}
            </.link>
            <.link
              navigate="/account/profile/domains"
              class={account_setting_secondary_link_class(@selected_link, "profile-domains")}
            >
              <.icon name="hero-globe-alt" class="w-4 h-4" /> {gettext("Profile Domains")}
            </.link>
            <.link
              navigate="/account/storage"
              class={account_setting_secondary_link_class(@selected_link, "storage")}
            >
              <.icon name="hero-circle-stack" class="w-4 h-4" /> {gettext("Storage")}
            </.link>
            <.link
              navigate="/account/files"
              class={account_setting_secondary_link_class(@selected_link, "files")}
            >
              <.icon name="hero-folder" class="w-4 h-4" /> {gettext("Files")}
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :selected_page, :string, required: true
  attr :selected_section, :string, default: nil
  attr :sections, :list, default: []
  attr :profile_url, :string, default: nil

  def profile_settings_sidebar(assigns) do
    ~H"""
    <div class="sticky top-24 self-start">
      <div class="card panel-card">
        <div class="card-body p-4">
          <h3 class="font-semibold text-sm mb-4">Profile</h3>

          <ul class="menu menu-compact w-full p-0 space-y-1">
            <li>
              <.link navigate="/account" class={profile_utility_link_class()}>
                <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back to Settings")}
              </.link>
            </li>
          </ul>

          <div :if={@profile_url} class="divider my-4"></div>

          <ul :if={@profile_url} class="menu menu-compact w-full p-0 space-y-1">
            <li :if={@profile_url}>
              <.link
                href={@profile_url}
                target="_blank"
                class={profile_utility_link_class()}
              >
                <.icon name="hero-eye" class="w-4 h-4" /> {gettext("View Profile")}
              </.link>
            </li>
          </ul>

          <div :if={@sections != []} class="divider my-4"></div>

          <h4 :if={@sections != []} class="font-semibold text-sm mb-4">Sections</h4>

          <ul :if={@sections != []} class="menu menu-compact w-full p-0 space-y-1">
            <%= for {section_id, section_icon, section_label} <- @sections do %>
              <li>
                <button
                  type="button"
                  phx-click="change_tab"
                  phx-value-tab={section_id}
                  class={account_setting_secondary_link_class(@selected_section, section_id)}
                >
                  <.icon name={section_icon} class="w-4 h-4" /> {section_label}
                </button>
              </li>
            <% end %>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :selected_page, :string, required: true

  def developer_settings_sidebar(assigns) do
    ~H"""
    <div class="sticky top-24 self-start">
      <div class="card panel-card">
        <div class="card-body p-4">
          <h3 class="font-semibold text-sm mb-4">{gettext("Developer")}</h3>

          <ul class="menu menu-compact w-full p-0 space-y-1">
            <li>
              <.link navigate="/account?tab=developer" class={profile_utility_link_class()}>
                <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back to Settings")}
              </.link>
            </li>
          </ul>

          <div class="divider my-4"></div>

          <ul class="menu menu-compact w-full p-0 space-y-1">
            <li>
              <.link
                navigate="/account/developer/oidc/clients"
                class={account_setting_secondary_link_class(@selected_page, "oidc-clients")}
              >
                <.icon name="hero-key" class="w-4 h-4" /> {gettext("OAuth Clients")}
              </.link>
            </li>
            <li>
              <.link
                navigate="/account/developer/oidc/grants"
                class={account_setting_secondary_link_class(@selected_page, "oidc-grants")}
              >
                <.icon name="hero-check-badge" class="w-4 h-4" /> {gettext("Granted Apps")}
              </.link>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp account_setting_tabs do
    [
      {"profile", "hero-user", :default},
      {"security", "hero-shield-check", :default},
      {"privacy", "hero-lock-closed", :default},
      {"preferences", "hero-cog-6-tooth", :default},
      {"notifications", "hero-bell", :default},
      {"federation", "hero-globe-alt", :default},
      {"timeline", "hero-queue-list", :default},
      {"email", "hero-envelope", :default},
      {"developer", "hero-code-bracket", :default},
      {"danger", "hero-exclamation-triangle", :danger}
    ]
    |> Enum.filter(fn {tab, _icon, _tone} -> account_setting_enabled?(tab) end)
  end

  defp account_setting_label("profile"), do: gettext("Profile")
  defp account_setting_label("security"), do: gettext("Security")
  defp account_setting_label("privacy"), do: gettext("Privacy")
  defp account_setting_label("preferences"), do: gettext("Preferences")
  defp account_setting_label("notifications"), do: gettext("Notifications")
  defp account_setting_label("federation"), do: gettext("Federation")
  defp account_setting_label("timeline"), do: gettext("Timeline")
  defp account_setting_label("email"), do: gettext("Email")
  defp account_setting_label("developer"), do: gettext("Developer")
  defp account_setting_label("danger"), do: gettext("Danger Zone")
  defp account_setting_label(_), do: gettext("Settings")

  defp account_setting_link_class(selected_tab, tab_id, tone) do
    base =
      "text-sm rounded-lg flex items-center gap-2 px-3 py-2 border transition-all duration-200"

    active? = selected_tab == tab_id

    case tone do
      :danger ->
        if active? do
          "#{base} border-error/40 bg-error/10 text-error shadow-sm"
        else
          "#{base} border-transparent text-error/80 hover:bg-error/10 hover:border-error/20"
        end

      _ ->
        if active? do
          "#{base} border-primary/40 bg-transparent text-primary shadow-sm"
        else
          "#{base} border-transparent text-base-content/70 hover:bg-base-200/80 hover:text-base-content"
        end
    end
  end

  defp account_setting_enabled?("email"), do: Modules.enabled?(:email)
  defp account_setting_enabled?(_tab), do: true

  defp account_setting_secondary_link_class(selected_link, link_id) do
    base =
      "text-sm rounded-lg flex items-center gap-2 px-3 py-2 border transition-all duration-200"

    if selected_link == link_id do
      "#{base} border-primary/35 bg-base-200/70 text-base-content font-medium"
    else
      "#{base} border-transparent text-base-content/80 hover:text-base-content hover:bg-base-200/60 hover:border-base-300"
    end
  end

  defp profile_utility_link_class do
    "btn btn-ghost btn-sm w-full justify-start border transition-all duration-200 border-transparent"
  end

  @doc """
  Renders a dismissible flash message.
  """
  attr :id, :string, default: nil
  attr :flash, :map, required: true
  attr :kind, :atom, values: [:info, :error], required: true
  attr :title, :string, default: nil
  attr :auto_dismiss_ms, :integer, default: 5000
  attr :exit_ms, :integer, default: 260
  attr :rest, :global
  slot :inner_block

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    tone_vars =
      case assigns.kind do
        :error ->
          Elektrine.Theme.inline_vars(%{
            "--flash-accent" => "color-mix(in srgb, var(--color-error) 92%, transparent)",
            "--flash-accent-soft" => "color-mix(in srgb, var(--color-error) 25%, transparent)",
            "--flash-tint-start" => "color-mix(in srgb, var(--color-error) 20%, transparent)",
            "--flash-tint-mid" => "color-mix(in srgb, var(--color-error) 8%, transparent)",
            "--flash-border" => "color-mix(in srgb, var(--color-error) 48%, transparent)",
            "--flash-icon" =>
              "color-mix(in srgb, var(--color-error) 72%, var(--color-error-content) 28%)"
          })

        _ ->
          Elektrine.Theme.inline_vars(%{
            "--flash-accent" => "color-mix(in srgb, var(--color-success) 90%, transparent)",
            "--flash-accent-soft" => "color-mix(in srgb, var(--color-success) 24%, transparent)",
            "--flash-tint-start" => "color-mix(in srgb, var(--color-success) 16%, transparent)",
            "--flash-tint-mid" => "color-mix(in srgb, var(--color-success) 6%, transparent)",
            "--flash-border" => "color-mix(in srgb, var(--color-success) 42%, transparent)",
            "--flash-icon" => "color-mix(in srgb, var(--color-success) 96%, transparent)"
          })
      end

    assigns = assign(assigns, :tone_vars, tone_vars)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role="alert"
      class={[
        "alert app-flash shadow-lg pointer-events-auto",
        @kind == :info && "app-flash--info",
        @kind == :error && "app-flash--error",
        "w-full"
      ]}
      data-flash-auto-dismiss="true"
      data-flash-auto-dismiss-ms={@auto_dismiss_ms}
      data-flash-exit-ms={@exit_ms}
      data-flash-kind={@kind}
      style={"--flash-auto-dismiss: #{@auto_dismiss_ms}ms; --flash-exit: #{@exit_ms}ms; #{@tone_vars}"}
      {@rest}
    >
      <.icon name={flash_icon(@kind)} class="h-5 w-5 flex-shrink-0" />
      <div class="min-w-0">
        <p class="font-semibold leading-tight">{@title || default_flash_title(@kind)}</p>
        <p class="text-sm break-words">{msg}</p>
      </div>
      <button
        type="button"
        class="btn btn-ghost btn-xs app-flash__dismiss"
        data-flash-dismiss="true"
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind})}
        aria-label="Dismiss notification"
      >
        <span class="sr-only">Dismiss</span>
        <.icon name="hero-x-mark-solid" class="h-4 w-4" />
      </button>
    </div>
    """
  end

  @doc """
  Renders info and error flashes in a fixed top-right stack.
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div
      id="flash-group"
      phx-hook="FlashAutoDismiss"
      class="fixed bottom-4 right-4 z-[1000] w-full max-w-sm px-4 sm:px-0 space-y-2 pointer-events-none"
    >
      <.flash kind={:info} title="Success" flash={@flash} auto_dismiss_ms={5000} />
      <.flash kind={:error} title="Error" flash={@flash} auto_dismiss_ms={5000} />
    </div>
    """
  end

  defp default_flash_title(:info), do: "Success"
  defp default_flash_title(:error), do: "Error"

  defp flash_icon(:info), do: "hero-check-circle-solid"
  defp flash_icon(:error), do: "hero-exclamation-circle-solid"

  # Email processing functions
  def process_email_html(html_content), do: Integrations.process_email_html(html_content)
  def clean_email_artifacts(content), do: Integrations.clean_email_artifacts(content)

  def safe_sanitize_email_html(html_content),
    do: Integrations.safe_sanitize_email_html(html_content)

  def permissive_email_sanitize(html_content),
    do: Integrations.permissive_email_sanitize(html_content)

  def safe_message_to_json(message), do: Integrations.safe_message_to_json(message)
  def decode_email_subject(subject), do: Integrations.decode_email_subject(subject)
  def format_email_display(email_string), do: Integrations.format_email_display(email_string)
end
