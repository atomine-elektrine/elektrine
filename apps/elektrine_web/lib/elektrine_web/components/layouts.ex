defmodule ElektrineWeb.Layouts do
  @moduledoc ~s|This module holds different layouts used by your application.\n\nSee the `layouts` directory for all templates available.\nThe \"root\" layout is a skeleton rendered as part of the\napplication router. The \"app\" layout is set as the default\nlayout on both `use ElektrineWeb, :controller` and\n`use ElektrineWeb, :live_view`.\n|
  use ElektrineWeb, :html
  import ElektrineWeb.Components.User.Avatar
  embed_templates("layouts/*")

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

      {ElektrineWeb.Admin.UsersController, :multi_accounts} ->
        "Multi-Accounts"

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

      {ElektrineWeb.Admin.AliasesController, :index} ->
        "Aliases"

      {ElektrineWeb.Admin.AliasesController, :forwarded_messages} ->
        "Forwarded Messages"

      {ElektrineWeb.Admin.MailboxesController, :index} ->
        "Mailboxes"

      {ElektrineWeb.Admin.MessagesController, :index} ->
        "Messages"

      {ElektrineWeb.Admin.MessagesController, :view} ->
        "View Message"

      {ElektrineWeb.Admin.MessagesController, :user_messages} ->
        "User Messages"

      {ElektrineWeb.Admin.MessagesController, :view_user_message} ->
        "View User Message"

      {ElektrineWeb.Admin.MonitoringController, :active_users} ->
        "Active Users"

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

      {ElektrineWeb.AdminUpdatesController, :index} ->
        "Platform Updates"

      {ElektrineWeb.AdminUpdatesController, :new} ->
        "New Platform Update"

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

      {ElektrineWeb.Admin.VPNController, :dashboard} ->
        "VPN Dashboard"

      {ElektrineWeb.Admin.VPNController, :new_server} ->
        "New VPN Server"

      {ElektrineWeb.Admin.VPNController, :edit_server} ->
        "Edit VPN Server"

      {ElektrineWeb.Admin.VPNController, :confirm_delete_server} ->
        "Delete VPN Server"

      {ElektrineWeb.Admin.VPNController, :users} ->
        "VPN Users"

      {ElektrineWeb.Admin.VPNController, :edit_user_config} ->
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
      {ElektrineWeb.AdminLive.MessagingFederation, :index} -> "Arblarg Messaging Federation"
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
    assigns[:meta_description] || "Elektrine - Email, VPN, and federated social platform"
  end

  @doc ~s|Builds the meta keywords for SEO.\n|
  def build_meta_keywords(assigns) do
    assigns[:meta_keywords] ||
      "email service, free email, VPN, social network, ActivityPub, Mastodon, fediverse, private messaging, encrypted chat, community forums, Elixir, Phoenix LiveView, privacy-focused, ad-free social media, federated social network"
  end

  @doc ~s|Gets the current URL from assigns if available.\n|
  def current_url(assigns) do
    assigns[:current_url]
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
    System.get_env("ONION_HOST")
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
        ElektrineWeb.Endpoint.url() <> "/images/og-image.png"

      image_url when is_binary(image_url) ->
        if String.starts_with?(image_url, "http") do
          image_url
        else
          ElektrineWeb.Endpoint.url() <> image_url
        end
    end
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
    "bg-gray-400"
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

    (is_binary(path) and String.starts_with?(path, "/chat")) or
      String.contains?(socket_view, "ChatLive")
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
      String.starts_with?(path, "/vpn") -> "green"
      String.starts_with?(path, "/admin") -> "red"
      String.starts_with?(path, "/sysadmin") -> "red"
      String.starts_with?(path, "/settings") -> "cyan"
      String.starts_with?(path, "/account") -> "cyan"
      true -> "purple"
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
      value == "" -> nil
      String.ends_with?(value, ".onion") -> value
      true -> value <> ".onion"
    end
  end

  defp normalize_onion_host(_) do
    nil
  end
end
