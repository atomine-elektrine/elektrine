defmodule ElektrineWeb.VPNLive.Index do
  use ElektrineWeb, :live_view

  alias Elektrine.VPN
  import ElektrineWeb.Components.Platform.ElektrineNav

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    # Set locale
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    if user do
      # Load user's VPN configs
      user_configs = VPN.list_user_configs(user.id)

      # Load available servers filtered by user's trust level
      available_servers = VPN.list_active_servers_for_user(user.trust_level)

      # Set timezone and time_format from user preferences
      timezone = if user && user.timezone, do: user.timezone, else: "Etc/UTC"
      time_format = if user && user.time_format, do: user.time_format, else: "12"

      {:ok,
       socket
       |> assign(:page_title, "VPN")
       |> assign(:user_configs, user_configs)
       |> assign(:available_servers, available_servers)
       |> assign(:show_qr_modal, false)
       |> assign(:qr_code_svg, nil)
       |> assign(:qr_config_name, nil)
       |> assign(:timezone, timezone)
       |> assign(:time_format, time_format)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You must be logged in to access VPN")
       |> redirect(to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("create_config", %{"server_id" => server_id}, socket) do
    user = socket.assigns.current_user
    server_id = String.to_integer(server_id)

    case VPN.create_user_config(user.id, server_id) do
      {:ok, _config} ->
        # Reload configs
        user_configs = VPN.list_user_configs(user.id)

        {:noreply,
         socket
         |> assign(:user_configs, user_configs)
         |> put_flash(:info, "VPN configuration created successfully!")}

      {:error, :server_not_active} ->
        {:noreply,
         socket
         |> put_flash(:error, "This server is not currently active.")}

      {:error, :no_available_ips} ->
        {:noreply,
         socket
         |> put_flash(:error, "No available IP addresses on this server. Contact support.")}

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        error_msg = inspect(errors)

        {:noreply,
         socket
         |> put_flash(:error, "Failed to create configuration: #{error_msg}")}
    end
  end

  def handle_event("delete_config", %{"config_id" => config_id}, socket) do
    config_id = String.to_integer(config_id)
    config = VPN.get_user_config!(config_id)

    # Verify ownership
    if config.user_id == socket.assigns.current_user.id do
      case VPN.delete_user_config(config) do
        {:ok, _} ->
          user_configs = VPN.list_user_configs(socket.assigns.current_user.id)

          {:noreply,
           socket
           |> assign(:user_configs, user_configs)
           |> put_flash(:info, "VPN configuration deleted")}

        {:error, _} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to delete configuration")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Unauthorized")}
    end
  end

  def handle_event("download_config", %{"config_id" => config_id}, socket) do
    config_id = String.to_integer(config_id)
    config = VPN.get_user_config!(config_id)

    # Verify ownership
    if config.user_id == socket.assigns.current_user.id do
      config_content = VPN.generate_config_file(config)

      # Sanitize filename: only alphanumeric, hyphens, underscores
      safe_name =
        config.vpn_server.name
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_-]/, "-")
        |> String.replace(~r/-+/, "-")
        |> String.trim("-")

      {:noreply,
       socket
       |> push_event("download_config", %{
         filename: "#{safe_name}.conf",
         content: config_content
       })}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Unauthorized")}
    end
  end

  def handle_event("show_qr_code", %{"config_id" => config_id}, socket) do
    config_id = String.to_integer(config_id)
    config = VPN.get_user_config!(config_id)

    # Verify ownership
    if config.user_id == socket.assigns.current_user.id do
      # Generate QR code for mobile devices
      config_content = VPN.generate_config_file(config)

      qr_code =
        config_content
        |> EQRCode.encode()
        |> EQRCode.svg(width: 300)

      {:noreply,
       socket
       |> assign(:show_qr_modal, true)
       |> assign(:qr_code_svg, qr_code)
       |> assign(:qr_config_name, config.vpn_server.name)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Unauthorized")}
    end
  end

  def handle_event("close_qr_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_qr_modal, false)
     |> assign(:qr_code_svg, nil)
     |> assign(:qr_config_name, nil)}
  end

  # Helper functions for the template

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "0 B"

  defp country_flag(country_code) do
    # Convert country code to flag emoji
    # A = 🇦 (U+1F1E6), so we offset by 127397 from ASCII
    country_code
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.map(fn char -> char + 127_397 end)
    |> List.to_string()
  end
end
