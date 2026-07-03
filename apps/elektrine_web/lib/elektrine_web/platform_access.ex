defmodule ElektrineWeb.PlatformAccess do
  @moduledoc """
  Web-layer mapping between routes/views and hoster-selectable platform modules.
  """

  alias Elektrine.Platform.Modules

  @path_prefixes [
    email: [
      "/email",
      "/emails",
      "/aliases",
      "/mailbox",
      "/jmap",
      "/calendar",
      "/.well-known/jmap",
      "/.well-known/mta-sts.txt",
      "/.well-known/autoconfig",
      "/autoconfig",
      "/unsubscribe",
      "/api/emails",
      "/api/aliases",
      "/api/mailbox",
      "/api/haraka",
      "/api/ext/v1/email",
      "/pripyat/mailboxes",
      "/pripyat/custom-domains",
      "/pripyat/haraka",
      "/pripyat/system-email",
      "/pripyat/aliases",
      "/pripyat/forwarded-messages",
      "/pripyat/messages",
      "/pripyat/unsubscribe-stats"
    ],
    chat: [
      "/chat",
      "/friends",
      "/_arblarg",
      "/api/private-attachments",
      "/api/servers",
      "/api/conversations",
      "/api/messages",
      "/api/ext/v1/chat",
      "/pripyat/arblarg/messages"
    ],
    social: [
      "/authorize_interaction",
      "/activitypub",
      "/communities",
      "/discussions",
      "/timeline",
      "/hashtag",
      "/gallery",
      "/videos",
      "/lists",
      "/filters",
      "/remote",
      "/users/",
      "/c/",
      "/relay",
      "/inbox",
      "/tags",
      "/media_proxy",
      "/api/social",
      "/api/ext/v1/social",
      "/pripyat/communities"
    ],
    nerve: ["/account/nerve", "/api/ext/v1/nerve", "/api/ext/nerve"],
    vpn: ["/vpn", "/api/vpn", "/pripyat/vpn"],
    dns: ["/dns", "/api/dns", "/api/ext/v1/dns", "/api/ext/dns", "/pripyat/dns"],
    uptime: ["/uptime"],
    kairo: ["/kairo", "/api/ext/v1/kairo"]
  ]

  @view_modules %{
    email: [
      :"Elixir.ElektrineEmailWeb.EmailLive.Compose",
      :"Elixir.ElektrineEmailWeb.EmailLive.Index",
      :"Elixir.ElektrineEmailWeb.EmailLive.Raw",
      :"Elixir.ElektrineEmailWeb.EmailLive.Search",
      :"Elixir.ElektrineEmailWeb.EmailLive.Settings",
      :"Elixir.ElektrineEmailWeb.EmailLive.Show",
      :"Elixir.ElektrineEmailWeb.ContactsLive.Index",
      :"Elixir.ElektrineEmailWeb.UnsubscribeLive.Show"
    ],
    chat: [:"Elixir.ArblargWeb.ChatLive.Index", :"Elixir.ElektrineWeb.FriendsLive"],
    social: [
      :"Elixir.ElektrineSocialWeb.DiscussionsLive.Community",
      :"Elixir.ElektrineSocialWeb.DiscussionsLive.Index",
      :"Elixir.ElektrineSocialWeb.DiscussionsLive.Post",
      :"Elixir.ElektrineSocialWeb.DiscussionsLive.Settings",
      :"Elixir.ElektrineSocialWeb.FiltersLive.Index",
      :"Elixir.ElektrineSocialWeb.GalleryLive.Index",
      :"Elixir.ElektrineSocialWeb.HashtagLive.Show",
      :"Elixir.ElektrineSocialWeb.ListLive.Index",
      :"Elixir.ElektrineSocialWeb.ListLive.Show",
      :"Elixir.ElektrineSocialWeb.RemotePostLive.Show",
      :"Elixir.ElektrineSocialWeb.RemoteUserLive.Show",
      :"Elixir.ElektrineSocialWeb.TimelineLive.Index",
      :"Elixir.ElektrineSocialWeb.TimelineLive.Post",
      :"Elixir.ElektrineSocialWeb.VideosLive.Index"
    ],
    nerve: [:"Elixir.ElektrineNerveWeb.NerveLive"],
    vpn: [:"Elixir.ElektrineVPNWeb.PageLive.VPNPolicy", :"Elixir.ElektrineVPNWeb.VPNLive.Index"],
    dns: [:"Elixir.ElektrineDNSWeb.DNSLive.Index"],
    uptime: [:"Elixir.ElektrineUptimeWeb.UptimeLive.Index"],
    kairo: [:"Elixir.ElektrineWeb.KairoLive.Index"]
  }

  @portal_views [:"Elixir.ElektrineWeb.PortalLive.Index"]
  @email_access_views [
    :"Elixir.ElektrineEmailWeb.EmailLive.Compose",
    :"Elixir.ElektrineEmailWeb.EmailLive.Index",
    :"Elixir.ElektrineEmailWeb.EmailLive.Raw",
    :"Elixir.ElektrineEmailWeb.EmailLive.Search",
    :"Elixir.ElektrineEmailWeb.EmailLive.Settings",
    :"Elixir.ElektrineEmailWeb.EmailLive.Show",
    :"Elixir.ElektrineEmailWeb.ContactsLive.Index",
    :"Elixir.ElektrineWeb.CalendarLive.Index"
  ]
  @communities_views [
    :"Elixir.ElektrineSocialWeb.DiscussionsLive.Community",
    :"Elixir.ElektrineSocialWeb.DiscussionsLive.Index",
    :"Elixir.ElektrineSocialWeb.DiscussionsLive.Post",
    :"Elixir.ElektrineSocialWeb.DiscussionsLive.Settings"
  ]
  @list_views [
    :"Elixir.ElektrineSocialWeb.ListLive.Index",
    :"Elixir.ElektrineSocialWeb.ListLive.Show"
  ]
  @timeline_views [
    :"Elixir.ElektrineSocialWeb.HashtagLive.Show",
    :"Elixir.ElektrineSocialWeb.RemotePostLive.Show",
    :"Elixir.ElektrineSocialWeb.RemoteUserLive.Show",
    :"Elixir.ElektrineSocialWeb.TimelineLive.Index",
    :"Elixir.ElektrineSocialWeb.TimelineLive.Post"
  ]

  def required_module_for_path(path) when is_binary(path) do
    Enum.find_value(path_prefixes(), fn {module, prefixes} ->
      if Enum.any?(prefixes, &path_matches?(path, &1)), do: module
    end)
  end

  def required_module_for_path(_path), do: nil

  def accessible_path?(path) do
    case required_module_for_path(path) do
      nil -> true
      module -> Modules.enabled?(module)
    end
  end

  def accessible_path?(path, current_user) do
    accessible_path?(path) and
      case required_access_module_for_path(path) do
        nil -> true
        module -> Elektrine.System.user_can_access_module?(current_user, module)
      end
  end

  def required_module_for_view(view) do
    Enum.find_value(view_modules(), fn {module, views} ->
      if view in views, do: module
    end)
  end

  def accessible_view?(view) do
    case required_module_for_view(view) do
      nil -> true
      module -> Modules.enabled?(module)
    end
  end

  def accessible_view?(view, current_user) do
    accessible_view?(view) and
      case required_access_module_for_view(view) do
        nil -> true
        module -> Elektrine.System.user_can_access_module?(current_user, module)
      end
  end

  def required_access_module_for_path(path) when is_binary(path) do
    cond do
      path_matches?(path, "/drive/share") ->
        nil

      path_matches?(path, "/vpn/policy") ->
        nil

      path_matches?(path, "/api/ext/v1/search") or path_matches?(path, "/api/ext/search") ->
        :portal

      path_matches?(path, "/portal") ->
        :portal

      path_matches?(path, "/chat") or path_matches?(path, "/api/private-attachments") or
        path_matches?(path, "/api/servers") or path_matches?(path, "/api/conversations") or
        path_matches?(path, "/api/messages") or path_matches?(path, "/api/chat") or
        path_matches?(path, "/api/ext/v1/chat") or path_matches?(path, "/api/ext/chat") ->
        :chat

      path_matches?(path, "/email") or path_matches?(path, "/calendar") or
        path_matches?(path, "/contacts") or path_matches?(path, "/calendars") or
        path_matches?(path, "/addressbooks") or path_matches?(path, "/principals/users") or
        path_matches?(path, "/jmap") or path_matches?(path, "/.well-known/jmap") or
        path_matches?(path, "/api/email") or path_matches?(path, "/api/emails") or
        path_matches?(path, "/api/aliases") or path_matches?(path, "/api/mailbox") or
        path_matches?(path, "/api/ext/v1/email") or path_matches?(path, "/api/ext/email") or
        path_matches?(path, "/api/ext/v1/contacts") or path_matches?(path, "/api/ext/contacts") or
        path_matches?(path, "/api/ext/v1/calendars") or path_matches?(path, "/api/ext/calendars") or
        path_matches?(path, "/api/ext/v1/events") or path_matches?(path, "/api/ext/events") ->
        :email

      path_matches?(path, "/communities") or path_matches?(path, "/discussions") or
          path_matches?(path, "/api/social/communities") ->
        :communities

      path_matches?(path, "/gallery") or path_matches?(path, "/videos") or
          path_matches?(path, "/api/social/upload") ->
        :gallery

      path_matches?(path, "/lists") ->
        :lists

      path_matches?(path, "/friends") or path_matches?(path, "/profiles") or
          path_matches?(path, "/api/social/friend-requests") ->
        :friends

      path_matches?(path, "/timeline") or path_matches?(path, "/hashtag") or
        path_matches?(path, "/post") or path_matches?(path, "/remote") or
        path_matches?(path, "/api/social") or path_matches?(path, "/api/ext/v1/social") or
          path_matches?(path, "/api/ext/social") ->
        :timeline

      path_matches?(path, "/account/nerve") or
        path_matches?(path, "/api/ext/v1/nerve") or
          path_matches?(path, "/api/ext/nerve") ->
        :nerve

      path_matches?(path, "/dns") or path_matches?(path, "/api/ext/v1/dns") or
          path_matches?(path, "/api/ext/dns") ->
        :dns

      path_matches?(path, "/vpn") or path_matches?(path, "/api/vpn") ->
        :vpn

      path_matches?(path, "/uptime") ->
        :uptime

      path_matches?(path, "/kairo") or path_matches?(path, "/api/ext/v1/kairo") ->
        :kairo

      path_matches?(path, "/account/storage") ->
        :storage

      path_matches?(path, "/account/drive") or path_matches?(path, "/drive-dav") ->
        :drive

      true ->
        nil
    end
  end

  def required_access_module_for_path(_path), do: nil

  def required_access_module_for_view(view) do
    cond do
      view in @portal_views ->
        :portal

      view in @view_modules.chat ->
        :chat

      view in @email_access_views ->
        :email

      view in @communities_views ->
        :communities

      view == :"Elixir.ElektrineSocialWeb.GalleryLive.Index" ->
        :gallery

      view in @list_views ->
        :lists

      view == :"Elixir.ElektrineWeb.FriendsLive" ->
        :friends

      view in @timeline_views ->
        :timeline

      view == :"Elixir.ElektrineNerveWeb.NerveLive" ->
        :nerve

      view == :"Elixir.ElektrineDNSWeb.DNSLive.Index" ->
        :dns

      view == :"Elixir.ElektrineVPNWeb.VPNLive.Index" ->
        :vpn

      view == :"Elixir.ElektrineUptimeWeb.UptimeLive.Index" ->
        :uptime

      view == :"Elixir.ElektrineWeb.KairoLive.Index" ->
        :kairo

      view == :"Elixir.ElektrineWeb.StorageLive" ->
        :storage

      view == :"Elixir.ElektrineWeb.DriveLive" ->
        :drive

      true ->
        nil
    end
  end

  defp path_matches?(path, prefix) do
    cond do
      path == prefix ->
        true

      String.ends_with?(prefix, "/") ->
        String.starts_with?(path, prefix)

      true ->
        String.starts_with?(path, prefix <> "/")
    end
  end

  defp path_prefixes, do: @path_prefixes

  defp view_modules, do: @view_modules
end
