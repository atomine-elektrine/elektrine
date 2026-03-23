defmodule ElektrineWeb.PlatformAccess do
  @moduledoc """
  Web-layer mapping between routes/views and hoster-selectable platform modules.
  """

  alias Elektrine.Platform.Modules

  @path_prefixes [
    {:vault, ["/account/password-manager", "/api/ext/v1/password-manager"]},
    {:dns, ["/dns", "/api/dns", "/pripyat/dns"]},
    {:email,
     [
       "/email",
       "/emails",
       "/aliases",
       "/mailbox",
       "/jmap",
       "/calendar",
       "/.well-known/jmap",
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
       "/pripyat/aliases",
       "/pripyat/forwarded-messages",
       "/pripyat/messages",
       "/pripyat/unsubscribe-stats"
     ]},
    {:vpn, ["/vpn", "/api/vpn", "/pripyat/vpn"]},
    {:chat,
     [
       "/chat",
       "/friends",
       "/_arblarg",
       "/api/private-attachments",
       "/api/servers",
       "/api/conversations",
       "/api/messages",
       "/api/ext/v1/chat",
       "/pripyat/arblarg/messages"
     ]},
    {:social,
     [
       "/authorize_interaction",
       "/activitypub",
       "/communities",
       "/discussions",
       "/timeline",
       "/hashtag",
       "/gallery",
       "/lists",
       "/remote",
       "/users/",
       "/c/",
       "/relay",
       "/inbox",
       "/tags",
       "/media_proxy",
       "/api/social",
       "/api/v1",
       "/api/v2",
       "/api/ext/v1/social",
       "/pripyat/communities"
     ]}
  ]

  @view_modules %{
    email: [
      ElektrineWeb.EmailLive.Compose,
      ElektrineWeb.EmailLive.Index,
      ElektrineWeb.EmailLive.Raw,
      ElektrineWeb.EmailLive.Search,
      ElektrineWeb.EmailLive.Settings,
      ElektrineWeb.EmailLive.Show
    ],
    vpn: [
      ElektrineWeb.PageLive.VPNPolicy,
      ElektrineWeb.VPNLive.Index
    ],
    chat: [
      ElektrineWeb.ChatLive.Index,
      ElektrineWeb.FriendsLive
    ],
    social: [
      ElektrineWeb.DiscussionsLive.Community,
      ElektrineWeb.DiscussionsLive.Index,
      ElektrineWeb.DiscussionsLive.Post,
      ElektrineWeb.DiscussionsLive.Settings,
      ElektrineWeb.GalleryLive.Index,
      ElektrineWeb.HashtagLive.Show,
      ElektrineWeb.ListLive.Index,
      ElektrineWeb.ListLive.Show,
      ElektrineWeb.RemotePostLive.Show,
      ElektrineWeb.RemoteUserLive.Show,
      ElektrineWeb.TimelineLive.Index,
      ElektrineWeb.TimelineLive.Post
    ],
    vault: [
      ElektrinePasswordManagerWeb.VaultLive
    ],
    dns: [
      ElektrineWeb.DNSLive.Index
    ]
  }

  def required_module_for_path(path) when is_binary(path) do
    Enum.find_value(@path_prefixes, fn {module, prefixes} ->
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

  def required_module_for_view(view) do
    Enum.find_value(@view_modules, fn {module, views} ->
      if view in views, do: module
    end)
  end

  def accessible_view?(view) do
    case required_module_for_view(view) do
      nil -> true
      module -> Modules.enabled?(module)
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
end
