defmodule ElektrineWeb.AdminHTML do
  @moduledoc """
  Admin panel templates and view functions.
  """

  use ElektrineWeb, :html

  alias Elektrine.Accounts.InviteCode
  alias Elektrine.Platform.Modules

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

  def invite_code_status(%InviteCode{} = invite_code) do
    cond do
      !invite_code.is_active -> :inactive
      InviteCode.expired?(invite_code) -> :expired
      InviteCode.exhausted?(invite_code) -> :exhausted
      true -> :active
    end
  end

  def invite_code_status_label(%InviteCode{} = invite_code),
    do: invite_code |> invite_code_status() |> invite_code_status_label()

  def invite_code_status_label(:active), do: "Active"
  def invite_code_status_label(:inactive), do: "Inactive"
  def invite_code_status_label(:expired), do: "Expired"
  def invite_code_status_label(:exhausted), do: "Exhausted"

  def invite_code_status_badge_class(%InviteCode{} = invite_code),
    do: invite_code |> invite_code_status() |> invite_code_status_badge_class()

  def invite_code_status_badge_class(:active), do: "badge-success"
  def invite_code_status_badge_class(:inactive), do: "badge-ghost"
  def invite_code_status_badge_class(:expired), do: "badge-warning"
  def invite_code_status_badge_class(:exhausted), do: "badge-error"

  def invite_code_card_class(%InviteCode{} = invite_code) do
    case invite_code_status(invite_code) do
      :active -> "border-success/20 bg-success/5"
      :inactive -> "border-base-300 bg-base-200/50"
      :expired -> "border-warning/25 bg-warning/10"
      :exhausted -> "border-error/25 bg-error/10"
    end
  end

  def invite_code_progress_class(%InviteCode{} = invite_code) do
    case invite_code_status(invite_code) do
      :active -> "progress-success"
      :inactive -> "progress"
      :expired -> "progress-warning"
      :exhausted -> "progress-error"
    end
  end

  def invite_code_status_blurb(%InviteCode{} = invite_code) do
    case invite_code_status(invite_code) do
      :active -> "Ready to unlock a new registration."
      :inactive -> "Disabled manually and unavailable for signup."
      :expired -> "Past its expiration time and no longer accepted."
      :exhausted -> "Usage limit reached and no longer accepted."
    end
  end

  def invite_code_usage_percent(%InviteCode{max_uses: max_uses, uses_count: uses_count})
      when is_integer(max_uses) and max_uses > 0 do
    uses_count
    |> Kernel./(max_uses)
    |> Kernel.*(100)
    |> min(100.0)
    |> round()
  end

  def invite_code_usage_percent(_), do: 0

  def activity_source_label(:web), do: "Web"
  def activity_source_label(:imap), do: "IMAP"
  def activity_source_label(:pop3), do: "POP3"
  def activity_source_label(_), do: "Unknown"

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
      if Elektrine.Strings.present?(search),
        do: params ++ ["search=#{URI.encode_www_form(search)}"],
        else: params

    params = if category != "all", do: params ++ ["category=#{category}"], else: params
    params = if status != "all", do: params ++ ["status=#{status}"], else: params
    params = params ++ ["page=#{page}"]

    "/admin/communities?" <> Enum.join(params, "&")
  end

  def build_custom_domains_url(search, status, page) do
    params = []

    params =
      if Elektrine.Strings.present?(search) do
        params ++ ["search=#{URI.encode_www_form(search)}"]
      else
        params
      end

    params = if status != "all", do: params ++ ["status=#{status}"], else: params
    params = params ++ ["page=#{page}"]

    "/pripyat/custom-domains?" <> Enum.join(params, "&")
  end

  def admin_nav_sections do
    [
      %{
        label: "Main",
        items: [
          %{label: "Dashboard", path: "/pripyat", icon: "hero-squares-2x2"}
        ]
      },
      %{
        label: "Users",
        items: [
          %{label: "Users", path: "/pripyat/users", icon: "hero-users"},
          %{
            label: "Multi-Accounts",
            path: "/pripyat/multi-accounts",
            icon: "hero-user-circle"
          },
          %{
            label: "Account Lookup",
            path: "/pripyat/account-lookup",
            icon: "hero-magnifying-glass"
          },
          %{
            label: "Invite Codes",
            path: "/pripyat/invite-codes",
            icon: "hero-ticket"
          },
          %{
            label: "Badges",
            path: "/pripyat/badges",
            icon: "hero-star",
            navigate: true
          }
        ]
      },
      %{
        label: "Email",
        items: [
          %{label: "VPN", path: "/pripyat/vpn", icon: "hero-shield-check", platform_module: :vpn},
          %{
            label: "Mailboxes",
            path: "/pripyat/mailboxes",
            icon: "hero-envelope",
            platform_module: :email
          },
          %{
            label: "Custom Domains",
            path: "/pripyat/custom-domains",
            icon: "hero-globe-alt",
            platform_module: :email
          },
          %{
            label: "Aliases",
            path: "/pripyat/aliases",
            icon: "hero-at-symbol",
            platform_module: :email
          },
          %{
            label: "Forwarded Messages",
            path: "/pripyat/forwarded-messages",
            icon: "hero-arrow-right-circle",
            platform_module: :email
          },
          %{
            label: "Messages",
            path: "/pripyat/messages",
            icon: "hero-chat-bubble-left-ellipsis",
            platform_module: :email
          },
          %{
            label: "Arblarg Messages",
            path: "/pripyat/arblarg/messages",
            icon: "hero-chat-bubble-left-right",
            platform_module: :chat
          }
        ]
      },
      %{
        label: "Content",
        items: [
          %{
            label: "Content Moderation",
            path: "/pripyat/content-moderation",
            icon: "hero-shield-exclamation"
          },
          %{
            label: "Communities",
            path: "/pripyat/communities",
            icon: "hero-user-group",
            platform_module: :social
          },
          %{
            label: "Reports",
            path: "/pripyat/reports",
            icon: "hero-flag",
            navigate: true
          },
          %{
            label: "Deletion Requests",
            path: "/pripyat/deletion-requests",
            icon: "hero-trash"
          }
        ]
      },
      %{
        label: "System",
        items: [
          %{
            label: "Audit Log",
            path: "/pripyat/audit-logs",
            icon: "hero-clipboard-document-list"
          },
          %{
            label: "Announcements",
            path: "/pripyat/announcements",
            icon: "hero-megaphone"
          },
          %{
            label: "Platform Updates",
            path: "/pripyat/updates",
            icon: "hero-newspaper"
          },
          %{
            label: "Subscriptions",
            path: "/pripyat/subscriptions",
            icon: "hero-credit-card"
          },
          %{
            label: "ActivityPub Policies",
            path: "/pripyat/federation",
            icon: "hero-globe-alt",
            navigate: true
          },
          %{
            label: "Arblarg Messaging",
            path: "/pripyat/messaging-federation",
            icon: "hero-chat-bubble-left-right",
            navigate: true
          },
          %{
            label: "Bluesky Bridge",
            path: "/pripyat/bluesky-bridge",
            icon: "hero-link",
            navigate: true
          },
          %{
            label: "ActivityPub Relays",
            path: "/pripyat/relays",
            icon: "hero-signal",
            navigate: true
          }
        ]
      }
    ]
    |> filter_nav_sections()
  end

  defp filter_nav_sections(sections) do
    sections
    |> Enum.map(fn section ->
      Map.update!(section, :items, fn items ->
        Enum.filter(items, fn item ->
          item
          |> Map.get(:platform_module)
          |> module_enabled?()
        end)
      end)
    end)
    |> Enum.reject(&(Enum.empty?(&1.items) and &1.label != "Main"))
  end

  defp module_enabled?(nil), do: true
  defp module_enabled?(module), do: Modules.enabled?(module)

  def custom_domain_filter_label("all"), do: "All Domains"
  def custom_domain_filter_label("verified"), do: "Verified"
  def custom_domain_filter_label("pending"), do: "Pending"
  def custom_domain_filter_label("attention"), do: "Needs Attention"
  def custom_domain_filter_label(_), do: "Custom Domains"

  def custom_domain_status_badge_class("verified"), do: "bg-success/15 text-success"
  def custom_domain_status_badge_class("pending"), do: "bg-secondary/15 text-secondary"
  def custom_domain_status_badge_class(_), do: "bg-base-200 text-base-content/70"

  def custom_domain_health(custom_domain) do
    cond do
      present_error?(custom_domain.dkim_last_error) -> :attention
      present_error?(custom_domain.last_error) -> :attention
      custom_domain.status == "verified" -> :healthy
      true -> :pending
    end
  end

  def custom_domain_health_badge_class(:healthy), do: "bg-success/15 text-success"
  def custom_domain_health_badge_class(:pending), do: "bg-info/15 text-info"
  def custom_domain_health_badge_class(:attention), do: "bg-warning/20 text-warning-content"
  def custom_domain_health_badge_class(_), do: "bg-base-200 text-base-content/70"

  def custom_domain_health_label(:healthy), do: "Healthy"
  def custom_domain_health_label(:pending), do: "Pending DNS"
  def custom_domain_health_label(:attention), do: "Needs Attention"
  def custom_domain_health_label(_), do: "Unknown"

  def custom_domain_primary_email(%{user: %{username: username}, domain: domain})
      when is_binary(username) and is_binary(domain) do
    "#{username}@#{domain}"
  end

  def custom_domain_primary_email(%{domain: domain}) when is_binary(domain), do: "@#{domain}"
  def custom_domain_primary_email(_), do: "Unavailable"

  def custom_domain_error_summary(custom_domain) do
    [custom_domain.last_error, custom_domain.dkim_last_error]
    |> Enum.filter(&present_error?/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      message -> message
    end
  end

  def custom_domain_dkim_state_label(custom_domain) do
    cond do
      present_error?(custom_domain.dkim_last_error) -> "Sync issue"
      custom_domain.dkim_synced_at -> "Synced"
      true -> "Waiting for sync"
    end
  end

  def custom_domain_dkim_state_class(custom_domain) do
    cond do
      present_error?(custom_domain.dkim_last_error) -> "text-warning"
      custom_domain.dkim_synced_at -> "text-success"
      true -> "text-base-content/55"
    end
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

  defp present_error?(value) when is_binary(value), do: Elektrine.Strings.present?(value)
  defp present_error?(_), do: false
end
