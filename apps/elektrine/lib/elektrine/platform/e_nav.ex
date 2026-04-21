defmodule Elektrine.Platform.ENav do
  @moduledoc false

  def primary_items do
    [
      %{
        id: "overview",
        label: "Overview",
        href: "/overview",
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
        id: "vault",
        label: "Vault",
        href: "/account/password-manager",
        platform_module: :vault,
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
        href: "/account/profile/analytics",
        icon: "hero-chart-bar",
        active_icon: "hero-chart-bar-solid"
      },
      %{
        id: "profile-domains",
        label: "Domains",
        href: "/account/profile/domains",
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
        id: "files",
        label: "Files",
        href: "/account/files",
        icon: "hero-folder",
        active_icon: "hero-folder-solid"
      },
      %{
        id: "notes",
        label: "Notes",
        href: "/account/notes",
        icon: "hero-document-text",
        active_icon: "hero-document-text-solid"
      }
    ]
  end
end
