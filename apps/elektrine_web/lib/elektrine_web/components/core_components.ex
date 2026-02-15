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

  # UI Components
  alias ElektrineWeb.Components.UI.Modal
  alias ElektrineWeb.Components.UI.Button
  alias ElektrineWeb.Components.UI.Form
  alias ElektrineWeb.Components.UI.Table
  alias ElektrineWeb.Components.UI.Icon
  alias ElektrineWeb.Components.UI.Card
  alias ElektrineWeb.Components.UI.Dropdown
  alias ElektrineWeb.Components.UI.EmptyState
  alias ElektrineWeb.Components.UI.Badge
  alias ElektrineWeb.Components.UI.Loading
  alias ElektrineWeb.Components.UI.BrandIcon

  # Layout Components
  alias ElektrineWeb.Components.Layout.Header
  alias ElektrineWeb.Components.Layout.Navigation
  alias ElektrineWeb.Components.Layout.Announcement

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

  # Email processing functions
  defdelegate process_email_html(html_content), to: Display
  defdelegate clean_email_artifacts(content), to: Display
  defdelegate safe_sanitize_email_html(html_content), to: Display
  defdelegate permissive_email_sanitize(html_content), to: Display
  defdelegate safe_message_to_json(message), to: Display
  defdelegate decode_email_subject(subject), to: Display
  defdelegate format_email_display(email_string), to: Display
end
