defmodule ElektrineWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use ElektrineWeb, :controller` and
  `use ElektrineWeb, :live_view`.
  """
  use ElektrineWeb, :html
  import ElektrineWeb.Components.User.Avatar

  embed_templates "layouts/*"

  @doc """
  Gets active announcements for display in layouts.
  This function is called from the layout templates.
  """
  def get_active_announcements do
    try do
      Elektrine.Admin.list_active_announcements()
    rescue
      _ -> []
    end
  end

  @doc """
  Gets active announcements for a specific user, excluding dismissed ones.
  """
  def get_active_announcements_for_user(user_id) do
    try do
      Elektrine.Admin.list_active_announcements_for_user(user_id)
    rescue
      _ -> []
    end
  end

  @doc """
  Builds the page title.
  """
  def build_page_title(assigns) do
    assigns[:page_title] || "Elektrine"
  end

  @doc """
  Builds the meta description for SEO.
  """
  def build_meta_description(assigns) do
    assigns[:meta_description] || "Elektrine - Email, VPN, and federated social platform"
  end

  @doc """
  Builds the meta keywords for SEO.
  """
  def build_meta_keywords(assigns) do
    assigns[:meta_keywords] ||
      "email service, free email, VPN, social network, ActivityPub, Mastodon, fediverse, private messaging, encrypted chat, community forums, Elixir, Phoenix LiveView, privacy-focused, ad-free social media, federated social network"
  end

  @doc """
  Gets the current URL from assigns if available.
  """
  def current_url(assigns) do
    assigns[:current_url]
  end

  @doc """
  Gets the OG image URL from assigns or uses default.
  """
  def og_image_url(assigns) do
    case assigns[:og_image] do
      nil ->
        ElektrineWeb.Endpoint.url() <> "/images/og-image.png"

      image_url when is_binary(image_url) ->
        # If it's already a full URL, use it
        if String.starts_with?(image_url, "http") do
          image_url
        else
          # Otherwise prepend the base URL
          ElektrineWeb.Endpoint.url() <> image_url
        end
    end
  end

  @doc """
  Gets the CSS class for status indicator based on user status.
  """
  def status_indicator_class("online"), do: "bg-success"
  def status_indicator_class("away"), do: "bg-warning"
  def status_indicator_class("dnd"), do: "bg-error"
  def status_indicator_class("offline"), do: "bg-gray-400"
  def status_indicator_class(_), do: "bg-success"

  @doc """
  Determines the grid color based on the current page/route.
  """
  def grid_color(assigns) do
    # Check for explicit grid_color in assigns first
    case assigns[:grid_color] do
      nil -> determine_grid_from_path(assigns)
      color -> color
    end
  end

  defp determine_grid_from_path(assigns) do
    path = get_current_path(assigns)

    cond do
      # Home page - red (matches blinkenlights)
      path == "/" -> "red"
      # Email - cyan
      String.starts_with?(path, "/email") -> "cyan"
      String.starts_with?(path, "/inbox") -> "cyan"
      # Chat - blue
      String.starts_with?(path, "/chat") -> "blue"
      # Timeline/Social - red
      String.starts_with?(path, "/timeline") -> "red"
      String.starts_with?(path, "/social") -> "red"
      # Discussions/Communities - orange
      String.starts_with?(path, "/discussions") -> "orange"
      String.starts_with?(path, "/d/") -> "orange"
      # Gallery - pink
      String.starts_with?(path, "/gallery") -> "pink"
      # VPN - green
      String.starts_with?(path, "/vpn") -> "green"
      # Admin - red
      String.starts_with?(path, "/admin") -> "red"
      String.starts_with?(path, "/sysadmin") -> "red"
      # Settings - cyan
      String.starts_with?(path, "/settings") -> "cyan"
      String.starts_with?(path, "/account") -> "cyan"
      # Default - purple
      true -> "purple"
    end
  end

  defp get_current_path(assigns) do
    cond do
      # LiveView socket
      assigns[:socket] && assigns.socket.view ->
        case assigns[:socket] do
          %{host_uri: %{path: path}} when is_binary(path) -> path
          _ -> get_path_from_uri(assigns)
        end

      # Conn-based request
      assigns[:conn] ->
        assigns.conn.request_path || "/"

      # Fallback - try to get from URI
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
end
