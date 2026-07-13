defmodule ElektrineWeb.Layouts do
  @moduledoc ~s|This module holds different layouts used by your application.\n\nSee the `layouts` directory for all templates available.\nThe \"root\" layout is a skeleton rendered as part of the\napplication router. The \"app\" layout is set as the default\nlayout on both `use ElektrineWeb, :controller` and\n`use ElektrineWeb, :live_view`.\n|
  use ElektrineWeb, :html
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.AdminHTML, only: [admin_nav_sections: 0]
  embed_templates("layouts/*")

  alias Elektrine.Platform.Modules
  alias Elektrine.RuntimeEnv
  alias Elektrine.Security.SafeExternalURL
  alias Elektrine.Theme

  @footer_wordmark_palette [
    "#a56b68",
    "#6f95c4",
    "#c99152",
    "#ffffff",
    "#5f87b8",
    "#6f8b74",
    "#7d99bb",
    "#c9853f"
  ]

  @doc ~s|Gets active announcements for display in layouts.\nThis function is called from the layout templates.\n|
  def get_active_announcements do
    Elektrine.Admin.list_active_announcements()
  rescue
    _ -> []
  end

  @doc ~s|Gets active announcements for a specific user, excluding dismissed ones.\n|
  def get_active_announcements_for_user(user_id) do
    Elektrine.Admin.list_active_announcements_for_user(user_id)
  rescue
    _ -> []
  end

  @doc ~s|The signed-in user's explicit theme mode, or nil for anonymous\nvisitors (who keep a browser-local light/dark toggle).\n|
  def site_theme_mode(assigns) do
    case assigns[:current_user] do
      %{theme_mode: mode} -> mode_or_default(mode)
      _ -> nil
    end
  end

  def site_theme_style(assigns) do
    if site_theme_mode(assigns) == "custom" do
      assigns
      |> current_user_theme_overrides()
      |> Theme.effective_style_attribute()
    else
      ""
    end
  end

  def site_theme_color(assigns) do
    case site_theme_mode(assigns) do
      "custom" ->
        assigns |> current_user_theme_overrides() |> Theme.effective_meta_theme_color()

      "light" ->
        Theme.effective_meta_theme_color()

      _ ->
        Theme.dark_meta_theme_color()
    end
  end

  def site_theme_name(assigns) do
    case site_theme_mode(assigns) do
      "light" ->
        "light"

      "custom" ->
        assigns |> current_user_theme_overrides() |> Theme.custom_scheme() |> to_string()

      _ ->
        "dark"
    end
  end

  def theme_boot_script do
    """
    (() => {
      try {
        const root = document.documentElement;
        const mode = root.dataset.themeMode;
        const systemTheme = window.matchMedia("(prefers-color-scheme: light)").matches
          ? "light"
          : "dark";
        if (mode === "light" || mode === "dark") {
          root.dataset.theme = mode;
        } else if (mode === "custom") {
          // Keep the server-resolved scheme derived from the custom palette.
        } else if (mode === "system") {
          root.dataset.theme = systemTheme;
        } else {
          const savedTheme = window.localStorage.getItem("elektrine:theme");
          root.dataset.theme = ["light", "dark"].includes(savedTheme)
            ? savedTheme
            : systemTheme;
        }
      } catch (_error) {
        document.documentElement.dataset.theme = "dark";
      }
    })();
    """
  end

  defp mode_or_default(mode) do
    if mode in Theme.modes(), do: mode, else: "system"
  end

  defp current_user_theme_overrides(assigns) do
    case assigns[:current_user] do
      %{theme_overrides: overrides} when is_map(overrides) -> overrides
      _ -> %{}
    end
  end

  @doc ~s|Builds the page title.\n|
  def build_page_title(assigns) do
    assigns[:page_title] || inferred_page_title(assigns) || "Elektrine"
  end

  defp inferred_page_title(assigns) do
    admin_controller_page_title(assigns) || admin_live_page_title(assigns) ||
      admin_path_page_title(assigns)
  end

  defp admin_controller_page_title(%{
         conn: %{private: %{phoenix_controller: controller, phoenix_action: action}}
       }) do
    case {controller, action} do
      {ElektrineWeb.AdminController, :dashboard} ->
        "Admin Dashboard"

      {ElektrineWeb.Admin.UsersController, :index} ->
        "User Management"

      {ElektrineWeb.Admin.UsersController, :new} ->
        "New User"

      {ElektrineWeb.Admin.UsersController, :edit} ->
        "Edit User"

      {ElektrineWeb.Admin.UsersController, :ban} ->
        "Ban User"

      {ElektrineWeb.Admin.UsersController, :account_lookup} ->
        "Account Lookup"

      {ElektrineWeb.Admin.UsersController, :search_accounts} ->
        "Account Lookup"

      {ElektrineEmailWeb.Admin.AliasesController, :index} ->
        "Aliases"

      {ElektrineEmailWeb.Admin.AliasesController, :forwarded_messages} ->
        "Forwarded Messages"

      {ElektrineEmailWeb.Admin.MailboxesController, :index} ->
        "Mailboxes"

      {ElektrineEmailWeb.Admin.MessagesController, :index} ->
        "Messages"

      {ElektrineEmailWeb.Admin.MessagesController, :view} ->
        "View Message"

      {ElektrineEmailWeb.Admin.MessagesController, :user_messages} ->
        "User Messages"

      {ElektrineEmailWeb.Admin.MessagesController, :view_user_message} ->
        "View User Message"

      {ElektrineWeb.Admin.MonitoringController, :active_users} ->
        "Active Users"

      {ElektrineWeb.Admin.MonitoringController, :operations} ->
        "Operations"

      {ElektrineWeb.Admin.MonitoringController, :imap_users} ->
        "IMAP Users"

      {ElektrineWeb.Admin.MonitoringController, :pop3_users} ->
        "POP3 Users"

      {ElektrineWeb.Admin.MonitoringController, :two_factor_status} ->
        "Two-Factor Status"

      {ElektrineWeb.Admin.DeletionRequestsController, :index} ->
        "Deletion Requests"

      {ElektrineWeb.Admin.DeletionRequestsController, :show} ->
        "Deletion Request"

      {ElektrineWeb.Admin.InviteCodesController, :index} ->
        "Invite Codes"

      {ElektrineWeb.Admin.InviteCodesController, :new} ->
        "New Invite Code"

      {ElektrineWeb.Admin.InviteCodesController, :edit} ->
        "Edit Invite Code"

      {ElektrineWeb.AdminAuditLogsController, :index} ->
        "Audit Logs"

      {ElektrineWeb.Admin.AnnouncementsController, :index} ->
        "Announcements"

      {ElektrineWeb.Admin.AnnouncementsController, :new} ->
        "New Announcement"

      {ElektrineWeb.Admin.AnnouncementsController, :edit} ->
        "Edit Announcement"

      {ElektrineWeb.Admin.CommunitiesController, :index} ->
        "Communities"

      {ElektrineWeb.Admin.CommunitiesController, :show} ->
        "Community Details"

      {ElektrineWeb.Admin.ModerationController, :content} ->
        "Content Moderation"

      {ElektrineWeb.Admin.ModerationController, :unsubscribe_stats} ->
        "Unsubscribe Statistics"

      {ElektrineWeb.Admin.SubscriptionsController, :index} ->
        "Subscription Products"

      {ElektrineWeb.Admin.SubscriptionsController, :new} ->
        "New Product"

      {ElektrineWeb.Admin.SubscriptionsController, :edit} ->
        "Edit Product"

      {ElektrineVPNWeb.Admin.VPNController, :dashboard} ->
        "VPN Dashboard"

      {ElektrineVPNWeb.Admin.VPNController, :new_server} ->
        "New VPN Server"

      {ElektrineVPNWeb.Admin.VPNController, :edit_server} ->
        "Edit VPN Server"

      {ElektrineVPNWeb.Admin.VPNController, :confirm_delete_server} ->
        "Delete VPN Server"

      {ElektrineVPNWeb.Admin.VPNController, :users} ->
        "VPN Users"

      {ElektrineVPNWeb.Admin.VPNController, :edit_user_config} ->
        "Edit VPN User Config"

      _ ->
        nil
    end
  end

  defp admin_controller_page_title(_), do: nil

  defp admin_live_page_title(%{socket: %{view: view}} = assigns) when is_atom(view) do
    case {view, assigns[:live_action]} do
      {ElektrineWeb.AdminLive.ReportsDashboard, :index} -> "Reports Dashboard"
      {ElektrineWeb.AdminLive.BadgeManagement, :index} -> "Badge Management"
      {ElektrineWeb.AdminLive.Federation, :index} -> "ActivityPub Federation"
      {ElektrineWeb.AdminLive.MessagingFederation, :index} -> "Chat Federation"
      {ElektrineWeb.AdminLive.BlueskyBridge, :index} -> "Bluesky Bridge"
      {ElektrineWeb.AdminLive.Relays, :index} -> "ActivityPub Relay Management"
      {ElektrineWeb.AdminLive.Emojis, :new} -> "New Custom Emoji"
      {ElektrineWeb.AdminLive.Emojis, :edit} -> "Edit Custom Emoji"
      {ElektrineWeb.AdminLive.Emojis, _} -> "Custom Emoji Management"
      _ -> nil
    end
  end

  defp admin_live_page_title(_), do: nil

  defp admin_path_page_title(assigns) do
    case get_current_path(assigns) do
      "/pripyat" ->
        "Admin Dashboard"

      "/pripyat/dashboard" ->
        "Live Dashboard"

      path when is_binary(path) ->
        if String.starts_with?(path, "/pripyat/") do
          path
          |> String.trim_leading("/pripyat/")
          |> String.split("/", trim: true)
          |> List.first()
          |> humanize_admin_path_segment()
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp humanize_admin_path_segment(nil), do: nil

  defp humanize_admin_path_segment(segment) when is_binary(segment) do
    segment
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc ~s|Builds the meta description for SEO.\n|
  def build_meta_description(assigns) do
    assigns[:meta_description] ||
      "Elektrine is a personal internet space for messages, identity, search, storage, and everyday tools."
  end

  @doc ~s|Builds the meta keywords for SEO.\n|
  def build_meta_keywords(assigns) do
    assigns[:meta_keywords] ||
      "email service, free email, VPN, social network, ActivityPub, Mastodon, fediverse, private messaging, encrypted chat, community forums, Elixir, Phoenix LiveView, privacy-focused, ad-free social media, federated social network"
  end

  @doc ~s|Builds the robots meta tag value.\n|
  def build_meta_robots(assigns) do
    assigns[:meta_robots] || "index, follow"
  end

  @doc ~s|Returns the global composer menu entries used by the app shell.\n|
  def global_composer_items(current_user \\ nil) do
    [
      %{
        id: "post",
        label: "Post",
        detail: "Share to timeline",
        href: Elektrine.Paths.timeline_path(composer: "post"),
        platform_module: :social,
        access_module: :timeline,
        icon: "hero-rectangle-stack"
      },
      %{
        id: "message",
        label: "Message",
        detail: "Start a direct message",
        href: Elektrine.Paths.chat_root_path(composer: "message"),
        platform_module: :chat,
        access_module: :chat,
        icon: "hero-chat-bubble-left-right"
      },
      %{
        id: "email",
        label: "Email",
        detail: "Compose a new email",
        href: Elektrine.Paths.email_compose_path(),
        platform_module: :email,
        access_module: :email,
        icon: "hero-envelope"
      },
      %{
        id: "task",
        label: "Task",
        detail: "Capture something to do",
        href: Elektrine.Paths.calendar_path(composer: "task"),
        platform_module: :email,
        access_module: :email,
        icon: "hero-check-circle"
      },
      %{
        id: "event",
        label: "Event",
        detail: "Schedule calendar time",
        href: Elektrine.Paths.calendar_path(composer: "event"),
        platform_module: :email,
        access_module: :email,
        icon: "hero-calendar"
      },
      %{
        id: "list",
        label: "List",
        detail: "Create a saved set of people",
        href: Elektrine.Paths.lists_path("create-list-panel"),
        platform_module: :social,
        access_module: :lists,
        icon: "hero-queue-list"
      }
    ]
    |> Enum.filter(&item_accessible?(&1, current_user))
  end

  @doc ~s|Returns true when a hoster-enabled platform module is available.\n|
  def platform_module_enabled?(nil), do: true
  def platform_module_enabled?(module), do: Modules.enabled?(module)

  def item_accessible?(item, current_user) do
    platform_module_enabled?(item[:platform_module]) and
      case item[:access_module] do
        nil -> true
        module -> Elektrine.System.user_can_access_module?(current_user, module)
      end
  end

  @doc ~s|Gets the current URL from assigns if available.\n|
  def current_url(assigns) do
    case SafeExternalURL.normalize_href(assigns[:current_url]) do
      {:ok, safe_url} -> safe_url
      {:error, _reason} -> nil
    end
  end

  @doc ~s|Returns true when the current request host is an onion service.\n|
  def via_tor_request?(assigns) do
    host =
      cond do
        assigns[:conn] && is_binary(assigns.conn.host) ->
          assigns.conn.host

        assigns[:socket] ->
          case assigns.socket do
            %{host_uri: %URI{host: host}} when is_binary(host) -> host
            _ -> nil
          end

        true ->
          nil
      end

    is_binary(host) and String.ends_with?(host, ".onion")
  end

  @doc ~s|Returns the onion host to display in the footer.\n\nPriority:\n1. `ONION_HOST` environment variable\n2. `/data/tor/elektrine/hostname` generated by Tor\n3. \"Not configured\"\n|
  def tor_onion_host do
    RuntimeEnv.present("ONION_HOST")
    |> normalize_onion_host()
    |> case do
      nil ->
        case File.read("/data/tor/elektrine/hostname") do
          {:ok, host} -> normalize_onion_host(host) || "Not configured"
          _ -> "Not configured"
        end

      host ->
        host
    end
  end

  @doc ~s|Gets the OG image URL from assigns or uses default.\n|
  def og_image_url(assigns) do
    case assigns[:og_image] do
      nil ->
        default_og_image_url()

      image_url when is_binary(image_url) ->
        safe_og_image_url(image_url) || default_og_image_url()
    end
  end

  defp default_og_image_url, do: ElektrineWeb.Endpoint.url() <> "/images/og-image.png"

  defp safe_og_image_url(image_url) do
    case SafeExternalURL.normalize_href(image_url) do
      {:ok, safe_url} ->
        safe_url

      {:error, _reason} ->
        if safe_local_image_path?(image_url) do
          ElektrineWeb.Endpoint.url() <> image_url
        end
    end
  end

  defp safe_local_image_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
      not Regex.match?(~r/[\x00-\x1F\x7F]/, path)
  end

  defp safe_local_image_path?(_path), do: false

  @doc ~s|Returns a stable hard-stop gradient for the footer wordmark.\n|
  def footer_wordmark_style(assigns \\ %{}) do
    seed = footer_wordmark_seed(assigns)
    band_count = 2 + rem(seed, 3)

    colors =
      @footer_wordmark_palette
      |> Enum.sort_by(&:erlang.phash2({seed, &1}))
      |> Enum.take(band_count)

    angle = rem(seed, 360)
    band_size = div(100, length(colors))

    stops =
      colors
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {color, index} ->
        start_pct = index * band_size
        end_pct = (index + 1) * band_size
        "#{color} #{start_pct}% #{end_pct}%"
      end)

    "background-image: linear-gradient(#{angle}deg, #{stops});"
  end

  defp footer_wordmark_seed(assigns) do
    host =
      cond do
        assigns[:conn] && is_binary(assigns.conn.host) ->
          assigns.conn.host

        assigns[:socket] ->
          case assigns.socket do
            %{host_uri: %URI{host: host}} when is_binary(host) -> host
            _ -> "elektrine"
          end

        true ->
          "elektrine"
      end

    :erlang.phash2({host, get_current_path(assigns)})
  end

  @doc ~s|Gets the CSS class for status indicator based on user status.\n|
  def status_indicator_class("online") do
    "bg-success"
  end

  def status_indicator_class("away") do
    "bg-warning"
  end

  def status_indicator_class("dnd") do
    "bg-error"
  end

  def status_indicator_class("offline") do
    "bg-base-content/40"
  end

  def status_indicator_class(_) do
    "bg-success"
  end

  @doc ~s|Determines the grid color based on the current page/route.\n|
  def grid_color(assigns) do
    case assigns[:grid_color] do
      nil -> determine_grid_from_path(assigns)
      color -> color
    end
  end

  @doc ~s|Returns true when the current page should use full-width main content.\n|
  def full_width_main?(assigns) do
    path = get_current_path(assigns)

    socket_view =
      case assigns[:socket] do
        %{view: view} when not is_nil(view) -> to_string(view)
        _ -> ""
      end

    full_width_path? =
      is_binary(path) and
        Enum.any?(
          [
            "/chat",
            "/timeline",
            "/gallery",
            "/videos",
            "/email",
            "/communities",
            "/analytics",
            "/d/"
          ],
          &String.starts_with?(path, &1)
        )

    full_width_path? or
      String.contains?(socket_view, "ChatLive") or
      String.contains?(socket_view, "ProfileLive.Analytics") or
      String.contains?(socket_view, "ProfileLive.DomainAnalytics")
  end

  @doc ~s|Returns the container class for system announcements.\n|
  def announcement_container_class(_assigns) do
    "mx-auto w-full max-w-7xl px-4 pt-6 sm:px-6 lg:px-8"
  end

  defp determine_grid_from_path(assigns) do
    path = get_current_path(assigns)

    cond do
      path == "/" -> "red"
      String.starts_with?(path, "/email") -> "cyan"
      String.starts_with?(path, "/inbox") -> "cyan"
      String.starts_with?(path, "/chat") -> "blue"
      String.starts_with?(path, "/timeline") -> "red"
      String.starts_with?(path, "/social") -> "red"
      String.starts_with?(path, "/discussions") -> "orange"
      String.starts_with?(path, "/d/") -> "orange"
      String.starts_with?(path, "/gallery") -> "pink"
      String.starts_with?(path, "/videos") -> "pink"
      String.starts_with?(path, "/vpn") -> "green"
      String.starts_with?(path, "/admin") -> "red"
      String.starts_with?(path, "/sysadmin") -> "red"
      String.starts_with?(path, "/settings") -> "cyan"
      String.starts_with?(path, "/account") -> "cyan"
      true -> "cyan"
    end
  end

  defp get_current_path(assigns) do
    cond do
      assigns[:socket] && assigns.socket.view ->
        case assigns[:socket] do
          %{host_uri: %{path: path}} when is_binary(path) -> path
          _ -> get_path_from_uri(assigns)
        end

      assigns[:conn] ->
        assigns.conn.request_path || "/"

      true ->
        get_path_from_uri(assigns)
    end
  end

  defp get_path_from_uri(assigns) do
    case assigns[:current_url] do
      nil ->
        "/"

      url when is_binary(url) ->
        case URI.parse(url) do
          %{path: path} when is_binary(path) -> path
          _ -> "/"
        end
    end
  end

  defp normalize_onion_host(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      not Elektrine.Strings.present?(value) -> nil
      String.ends_with?(value, ".onion") -> value
      true -> value <> ".onion"
    end
  end

  defp normalize_onion_host(_) do
    nil
  end
end
