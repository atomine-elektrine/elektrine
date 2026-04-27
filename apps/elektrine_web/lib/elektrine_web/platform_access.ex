defmodule ElektrineWeb.PlatformAccess do
  @moduledoc """
  Web-layer mapping between routes/views and hoster-selectable platform modules.
  """

  alias Elektrine.Platform.Modules

  @optional_route_modules [
    {:email, ElektrineWeb.Routes.Email},
    {:chat, ElektrineWeb.Routes.Chat},
    {:social, ElektrineWeb.Routes.Social},
    {:vault, ElektrineWeb.Routes.Vault},
    {:vpn, ElektrineWeb.Routes.VPN},
    {:dns, ElektrineWeb.Routes.DNS}
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

      path_matches?(path, "/gallery") or path_matches?(path, "/api/social/upload") or
        path_matches?(path, "/api/v1/media") or path_matches?(path, "/api/v2/media") ->
        :gallery

      path_matches?(path, "/lists") or path_matches?(path, "/api/v1/lists") or
          path_matches?(path, "/api/v1/timelines/list") ->
        :lists

      path_matches?(path, "/friends") or path_matches?(path, "/profiles") or
          path_matches?(path, "/api/social/friend-requests") ->
        :friends

      path_matches?(path, "/timeline") or path_matches?(path, "/hashtag") or
        path_matches?(path, "/post") or path_matches?(path, "/remote") or
        path_matches?(path, "/api/social") or path_matches?(path, "/api/v1") or
        path_matches?(path, "/api/v2") or path_matches?(path, "/api/ext/v1/social") or
          path_matches?(path, "/api/ext/social") ->
        :timeline

      path_matches?(path, "/account/password-manager") or
        path_matches?(path, "/api/ext/v1/password-manager") or
          path_matches?(path, "/api/ext/password-manager") ->
        :vault

      path_matches?(path, "/dns") or path_matches?(path, "/api/ext/v1/dns") or
          path_matches?(path, "/api/ext/dns") ->
        :dns

      path_matches?(path, "/vpn") or path_matches?(path, "/api/vpn") ->
        :vpn

      path_matches?(path, "/account/storage") ->
        :storage

      path_matches?(path, "/account/drive") or path_matches?(path, "/drive-dav") ->
        :drive

      path_matches?(path, "/account/notes") ->
        :notes

      true ->
        nil
    end
  end

  def required_access_module_for_path(_path), do: nil

  def required_access_module_for_view(view) do
    cond do
      view == ElektrineWeb.PortalLive.Index ->
        :portal

      view == ElektrineChatWeb.ChatLive.Index ->
        :chat

      view in [
        ElektrineEmailWeb.EmailLive.Compose,
        ElektrineEmailWeb.EmailLive.Index,
        ElektrineEmailWeb.EmailLive.Raw,
        ElektrineEmailWeb.EmailLive.Search,
        ElektrineEmailWeb.EmailLive.Settings,
        ElektrineEmailWeb.EmailLive.Show,
        ElektrineEmailWeb.ContactsLive.Index,
        ElektrineWeb.CalendarLive.Index
      ] ->
        :email

      view in [
        ElektrineSocialWeb.DiscussionsLive.Community,
        ElektrineSocialWeb.DiscussionsLive.Index,
        ElektrineSocialWeb.DiscussionsLive.Post,
        ElektrineSocialWeb.DiscussionsLive.Settings
      ] ->
        :communities

      view == ElektrineSocialWeb.GalleryLive.Index ->
        :gallery

      view in [ElektrineSocialWeb.ListLive.Index, ElektrineSocialWeb.ListLive.Show] ->
        :lists

      view == ElektrineWeb.FriendsLive ->
        :friends

      view in [
        ElektrineSocialWeb.HashtagLive.Show,
        ElektrineSocialWeb.RemotePostLive.Show,
        ElektrineSocialWeb.RemoteUserLive.Show,
        ElektrineSocialWeb.TimelineLive.Index,
        ElektrineSocialWeb.TimelineLive.Post
      ] ->
        :timeline

      view == ElektrinePasswordManagerWeb.VaultLive ->
        :vault

      view == ElektrineDNSWeb.DNSLive.Index ->
        :dns

      view == ElektrineVPNWeb.VPNLive.Index ->
        :vpn

      view == ElektrineWeb.StorageLive ->
        :storage

      view == ElektrineWeb.DriveLive ->
        :drive

      view == ElektrineWeb.NotesLive ->
        :notes

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

  defp path_prefixes do
    optional_route_metadata(:path_prefixes)
  end

  defp view_modules do
    Map.new(optional_route_metadata(:view_modules))
  end

  defp optional_route_metadata(function) do
    Enum.flat_map(@optional_route_modules, fn {module_id, route_module} ->
      if Code.ensure_loaded?(route_module) and function_exported?(route_module, function, 0) do
        [{module_id, apply(route_module, function, [])}]
      else
        []
      end
    end)
  end
end
