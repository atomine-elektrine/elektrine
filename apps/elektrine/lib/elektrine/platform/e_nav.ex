defmodule Elektrine.Platform.ENav do
  @moduledoc false

  alias Elektrine.Accounts.Storage
  alias Elektrine.{Friends, Messaging, Notifications, Profiles}
  alias Elektrine.Profiles.CustomDomains

  def primary_items do
    [
      %{
        id: "portal",
        label: "Portal",
        href: "/portal",
        platform_module: nil,
        icon: "hero-squares-2x2",
        active_icon: "hero-squares-2x2-solid"
      },
      %{
        id: "chat",
        label: "Chat",
        href: "/chat",
        platform_module: :chat,
        icon: "hero-chat-bubble-left-right",
        active_icon: "hero-chat-bubble-left-right-solid"
      },
      %{
        id: "timeline",
        label: "Timeline",
        href: "/timeline",
        platform_module: :social,
        icon: "hero-rectangle-stack",
        active_icon: "hero-rectangle-stack-solid"
      },
      %{
        id: "discussions",
        label: "Communities",
        href: "/communities",
        platform_module: :social,
        icon: "hero-chat-bubble-bottom-center-text",
        active_icon: "hero-chat-bubble-bottom-center-text-solid"
      },
      %{
        id: "gallery",
        label: "Gallery",
        href: "/gallery",
        platform_module: :social,
        icon: "hero-photo",
        active_icon: "hero-photo-solid"
      },
      %{
        id: "lists",
        label: "Lists",
        href: "/lists",
        platform_module: :social,
        icon: "hero-queue-list",
        active_icon: "hero-queue-list-solid"
      },
      %{
        id: "friends",
        label: "Friends",
        href: "/friends",
        platform_module: :chat,
        icon: "hero-user-group",
        active_icon: "hero-user-group-solid"
      },
      %{
        id: "email",
        label: "Email",
        href: "/email",
        platform_module: :email,
        icon: "hero-envelope",
        active_icon: "hero-envelope-solid"
      },
      %{
        id: "nerve",
        label: "Bridge",
        href: "/account/nerve",
        platform_module: :nerve,
        icon: "hero-key",
        active_icon: "hero-key-solid"
      },
      %{
        id: "dns",
        label: "DNS",
        href: "/dns",
        platform_module: :dns,
        icon: "hero-globe-alt",
        active_icon: "hero-globe-alt-solid"
      },
      %{
        id: "vpn",
        label: "VPN",
        href: "/vpn",
        platform_module: :vpn,
        icon: "hero-shield-check",
        active_icon: "hero-shield-check-solid"
      }
    ]
  end

  def secondary_items do
    [
      %{
        id: "account",
        label: "Account",
        href: "/account",
        icon: "hero-cog-6-tooth",
        active_icon: "hero-cog-6-tooth-solid"
      },
      %{
        id: "profile",
        label: "Profile",
        href: "/account/profile/edit",
        icon: "hero-user-circle",
        active_icon: "hero-user-circle-solid"
      },
      %{
        id: "profile-analytics",
        label: "Analytics",
        href: "/analytics/profile",
        icon: "hero-chart-bar",
        active_icon: "hero-chart-bar-solid"
      },
      %{
        id: "profile-domains",
        label: "Domains",
        href: "/domains",
        icon: "hero-globe-alt",
        active_icon: "hero-globe-alt-solid"
      },
      %{
        id: "storage",
        label: "Storage",
        href: "/account/storage",
        icon: "hero-circle-stack",
        active_icon: "hero-circle-stack-solid"
      },
      %{
        id: "drive",
        label: "Drive",
        href: "/account/drive",
        icon: "hero-folder",
        active_icon: "hero-folder-solid"
      },
      %{
        id: "notes",
        label: "Notes",
        href: "/account/notes",
        icon: "hero-document-text",
        active_icon: "hero-document-text-solid"
      },
      %{
        id: "proofs",
        label: "Proofs",
        href: "/account/proofs",
        icon: "hero-identification",
        active_icon: "hero-identification-solid"
      }
    ]
  end

  def with_badge_counts(items, badge_counts) when is_map(badge_counts) do
    Enum.map(items, fn item ->
      count = Map.get(badge_counts, item.id, 0)

      if count > 0,
        do: Map.put(item, :badge_count, count),
        else: item
    end)
  end

  def with_badge_counts(items, _badge_counts), do: items

  def with_notification_badges(items, current_user) do
    with_badge_counts(items, notification_badge_counts(current_user))
  end

  def notification_badge_counts(nil), do: %{}

  def notification_badge_counts(%{id: user_id} = current_user) when is_integer(user_id) do
    %{
      "portal" => safe_count(fn -> Notifications.get_unread_count(user_id) end),
      "chat" => safe_count(fn -> Messaging.get_unread_count(user_id) end),
      "friends" => safe_count(fn -> friend_request_count(user_id) end),
      "email" => safe_count(fn -> email_unread_count(user_id) end),
      "account" => account_alert_count(current_user),
      "profile-domains" => safe_count(fn -> pending_domain_count(user_id) end),
      "storage" => safe_count(fn -> storage_alert_count(user_id) end),
      "proofs" => safe_count(fn -> pending_proof_count(user_id) end)
    }
  end

  def notification_badge_counts(_current_user), do: %{}

  defp friend_request_count(user_id) do
    Friends.get_pending_request_count(user_id) +
      length(Profiles.get_pending_follow_requests(user_id))
  end

  defp email_unread_count(user_id) do
    if module_exported?(Elektrine.Email, :get_user_mailbox, 1) and
         module_exported?(Elektrine.Email, :unread_inbox_count, 1) do
      case Elektrine.Email.get_user_mailbox(user_id) do
        %{id: mailbox_id} when is_integer(mailbox_id) ->
          Elektrine.Email.unread_inbox_count(mailbox_id)

        _ ->
          0
      end
    else
      0
    end
  end

  defp pending_domain_count(user_id) do
    profile_domains =
      user_id
      |> CustomDomains.list_user_custom_domains()
      |> Enum.count(&pending_status?/1)

    profile_domains + pending_email_domain_count(user_id)
  end

  defp pending_email_domain_count(user_id) do
    if module_exported?(Elektrine.Email, :list_user_custom_domains, 1) do
      user_id
      |> Elektrine.Email.list_user_custom_domains()
      |> Enum.count(&pending_status?/1)
    else
      0
    end
  end

  defp storage_alert_count(user_id) do
    case Storage.get_storage_info(user_id) do
      %{over_limit: true} -> 1
      _ -> 0
    end
  end

  defp pending_proof_count(user_id) do
    if module_exported?(Atomine.Personhood, :list_proofs, 1) do
      user_id
      |> Atomine.Personhood.list_proofs()
      |> Enum.count(&match?(%{status: "pending"}, &1))
    else
      0
    end
  end

  defp account_alert_count(current_user) do
    [
      recovery_email_needs_verification?(current_user),
      Map.get(current_user, :email_sending_restricted) == true
    ]
    |> Enum.count(& &1)
  end

  defp recovery_email_needs_verification?(%{
         recovery_email: email,
         recovery_email_verified: verified
       })
       when is_binary(email) do
    String.trim(email) != "" and verified != true
  end

  defp recovery_email_needs_verification?(_current_user), do: false

  defp pending_status?(%{status: "verified"}), do: false
  defp pending_status?(%{status: status}) when is_binary(status), do: true
  defp pending_status?(_domain), do: false

  defp module_exported?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp safe_count(fun) when is_function(fun, 0) do
    fun.()
    |> normalize_count()
  rescue
    _error -> 0
  end

  defp normalize_count(count) when is_integer(count), do: max(count, 0)
  defp normalize_count(count) when is_list(count), do: length(count)
  defp normalize_count(_count), do: 0
end
