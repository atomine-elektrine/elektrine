defmodule ElektrineWeb.AdminHTML do
  @moduledoc """
  Admin panel templates and view functions.
  """

  use ElektrineWeb, :html

  embed_templates "admin_html/*"

  # Helper functions for announcements
  def type_badge_class("info"), do: "badge-info"
  def type_badge_class("warning"), do: "badge-warning"
  def type_badge_class("maintenance"), do: "badge-neutral"
  def type_badge_class("feature"), do: "badge-success"
  def type_badge_class("urgent"), do: "badge-error"
  def type_badge_class(_), do: "badge-info"

  def currently_visible?(announcement) do
    Elektrine.Admin.Announcement.currently_active?(announcement)
  end

  def format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  def format_datetime_local(nil), do: ""

  def format_datetime_local(datetime) do
    # Format datetime for HTML datetime-local input
    # Format: YYYY-MM-DDTHH:mm
    Calendar.strftime(datetime, "%Y-%m-%dT%H:%M")
  end

  def time_ago_in_words(datetime), do: Elektrine.TextHelpers.time_ago_in_words(datetime)

  # Email integrity monitoring helpers
  def get_status_color(:healthy), do: "text-success"
  def get_status_color(:checking), do: "text-info"
  def get_status_color(:issues_detected), do: "text-warning"
  def get_status_color(:error), do: "text-error"
  def get_status_color(_), do: "text-base-content"

  def get_status_text(:healthy), do: "HEALTHY"
  def get_status_text(:checking), do: "CHECKING..."
  def get_status_text(:issues_detected), do: "ISSUES DETECTED"
  def get_status_text(:error), do: "ERROR"
  def get_status_text(_), do: "UNKNOWN"

  def get_severity_class(:critical), do: "badge-error"
  def get_severity_class(:high), do: "badge-warning"
  def get_severity_class(:medium), do: "badge-warning badge-outline"
  def get_severity_class(_), do: "badge-info"

  def format_issue_type(:routing_mismatch), do: "Routing Mismatch"
  def format_issue_type(:duplicate_mailbox_email), do: "Duplicate Email"
  def format_issue_type(:orphaned_mailbox), do: "Orphaned Mailbox"
  def format_issue_type(:duplicate_message_id), do: "Duplicate Message"

  def format_issue_type(type),
    do: String.replace(to_string(type), "_", " ") |> String.capitalize()

  def format_issue_description(%{type: :routing_mismatch} = issue) do
    "TO: #{issue.to_address} → Mailbox: #{issue.mailbox_email}"
  end

  def format_issue_description(%{type: :duplicate_mailbox_email} = issue) do
    "Email: #{issue.email} (#{issue.count} mailboxes)"
  end

  def format_issue_description(%{type: :orphaned_mailbox} = issue) do
    "#{issue.email} (#{issue.message_count} messages)"
  end

  def format_issue_description(%{type: :duplicate_message_id} = issue) do
    "Message ID: #{issue.message_id} (#{issue.count} copies)"
  end

  def format_issue_description(_issue), do: "Unknown issue"

  # Content moderation helper functions
  def truncate_content(nil), do: ""

  def truncate_content(content) when is_binary(content) do
    if String.length(content) > 150 do
      String.slice(content, 0, 150) <> "..."
    else
      content
    end
  end

  def content_type_badge("dm"), do: "badge-info"
  def content_type_badge("group"), do: "badge-accent"
  def content_type_badge("channel"), do: "badge-secondary"
  def content_type_badge(_), do: "badge-ghost"

  # Helper to build communities URL with filters
  def build_communities_url(search, category, status, page) do
    params = []

    params =
      if search != "", do: params ++ ["search=#{URI.encode_www_form(search)}"], else: params

    params = if category != "all", do: params ++ ["category=#{category}"], else: params
    params = if status != "all", do: params ++ ["status=#{status}"], else: params
    params = params ++ ["page=#{page}"]

    "/admin/communities?" <> Enum.join(params, "&")
  end

  # VPN helper - render country flag emoji
  def render_country_flag(country_code) when is_binary(country_code) do
    country_code
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.map(fn char -> char + 127_397 end)
    |> List.to_string()
  end

  def render_country_flag(_), do: ""

  # VPN helper - format bytes for display
  def format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_bytes(_), do: "0 B"
end
