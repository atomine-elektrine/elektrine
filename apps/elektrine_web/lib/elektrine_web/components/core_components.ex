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
  alias Phoenix.LiveView.JS

  # UI Components
  alias ElektrineWeb.Components.UI.Badge
  alias ElektrineWeb.Components.UI.BrandIcon
  alias ElektrineWeb.Components.UI.Button
  alias ElektrineWeb.Components.UI.Card
  alias ElektrineWeb.Components.UI.Dropdown
  alias ElektrineWeb.Components.UI.EmptyState
  alias ElektrineWeb.Components.UI.Form
  alias ElektrineWeb.Components.UI.Icon
  alias ElektrineWeb.Components.UI.Loading
  alias ElektrineWeb.Components.UI.Modal
  alias ElektrineWeb.Components.UI.Table

  # Layout Components
  alias ElektrineWeb.Components.Layout.Announcement
  alias ElektrineWeb.Components.Layout.Header
  alias ElektrineWeb.Components.Layout.Navigation

  # Datetime Components
  alias ElektrineWeb.Components.Datetime.LocalTime

  # Email Components
  alias ElektrineWeb.Components.Email.Display

  # Modal component and helpers
  defdelegate modal(assigns), to: Modal
  defdelegate show(js \\ %Phoenix.LiveView.JS{}, selector), to: Modal
  defdelegate hide(js \\ %Phoenix.LiveView.JS{}, selector), to: Modal
  defdelegate show_modal(js \\ %Phoenix.LiveView.JS{}, id), to: Modal
  defdelegate hide_modal(js \\ %Phoenix.LiveView.JS{}, id), to: Modal

  # Button component
  defdelegate button(assigns), to: Button

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
          "--flash-accent: rgba(239, 68, 68, 0.92); --flash-accent-soft: rgba(239, 68, 68, 0.25); --flash-tint-start: rgba(239, 68, 68, 0.2); --flash-tint-mid: rgba(239, 68, 68, 0.08); --flash-border: rgba(239, 68, 68, 0.48); --flash-icon: rgba(248, 113, 113, 0.98);"

        _ ->
          "--flash-accent: rgba(34, 197, 94, 0.9); --flash-accent-soft: rgba(34, 197, 94, 0.24); --flash-tint-start: rgba(34, 197, 94, 0.16); --flash-tint-mid: rgba(34, 197, 94, 0.06); --flash-border: rgba(34, 197, 94, 0.42); --flash-icon: rgba(34, 197, 94, 0.96);"
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
  defdelegate process_email_html(html_content), to: Display
  defdelegate clean_email_artifacts(content), to: Display
  defdelegate safe_sanitize_email_html(html_content), to: Display
  defdelegate permissive_email_sanitize(html_content), to: Display
  defdelegate safe_message_to_json(message), to: Display
  defdelegate decode_email_subject(subject), to: Display
  defdelegate format_email_display(email_string), to: Display
end
