defmodule ElektrineVPNWeb.VPNLive.Index do
  use ElektrineVPNWeb, :live_view

  alias Elektrine.VPN
  import ElektrineVPNWeb.Components.Platform.ElektrineNav

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    # Set locale
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    cond do
      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "You must be logged in to access VPN")
         |> redirect(to: Elektrine.Paths.login_path())}

      not VPN.user_can_access?(user) ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "VPN unlocks at trust level #{VPN.minimum_trust_level()} to reduce abuse."
         )
         |> redirect(to: ~p"/portal")}

      true ->
        # Load user's VPN configs
        user_configs = VPN.list_user_configs(user.id)

        # Load available servers filtered by user's trust level
        available_servers =
          if user.is_admin,
            do: VPN.list_active_servers(),
            else: VPN.list_active_servers_for_user(user.trust_level)

        # Set timezone and time_format from user preferences
        timezone = user.timezone || "Etc/UTC"
        time_format = user.time_format || "12"

        {:ok,
         socket
         |> assign(:page_title, "VPN")
         |> assign(:user_configs, user_configs)
         |> assign(:available_servers, available_servers)
         |> assign(:show_qr_modal, false)
         |> assign(:qr_code_svg, nil)
         |> assign(:qr_config, nil)
         |> assign(:qr_config_name, nil)
         |> assign(:timezone, timezone)
         |> assign(:time_format, time_format)}
    end
  end

  @impl true
  def handle_event("create_config", %{"server_id" => server_id_param}, socket) do
    user = socket.assigns.current_user

    case parse_id(server_id_param) do
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid server.")}

      {:ok, server_id} ->
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

          {:error, :insufficient_trust_level} ->
            {:noreply,
             socket
             |> put_flash(:error, "You do not have access to this VPN server.")}

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
  end

  def handle_event("delete_config", %{"config_id" => config_id_param}, socket) do
    case parse_id(config_id_param) do
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid configuration.")}

      {:ok, config_id} ->
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
  end

  def handle_event("download_config", %{"config_id" => config_id_param}, socket) do
    case parse_id(config_id_param) do
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid configuration.")}

      {:ok, config_id} ->
        config = VPN.get_user_config!(config_id)

        # Verify ownership
        if config.user_id == socket.assigns.current_user.id do
          config_content = VPN.generate_config_file(config)

          {:noreply,
           socket
           |> push_event("download_config", %{
             filename: VPN.config_download_filename(config),
             content: config_content
           })}
        else
          {:noreply,
           socket
           |> put_flash(:error, "Unauthorized")}
        end
    end
  end

  def handle_event("show_qr_code", %{"config_id" => config_id_param}, socket) do
    case parse_id(config_id_param) do
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid configuration.")}

      {:ok, config_id} ->
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
           |> assign(:qr_config, config)
           |> assign(:qr_config_name, config.vpn_server.name)}
        else
          {:noreply,
           socket
           |> put_flash(:error, "Unauthorized")}
        end
    end
  end

  def handle_event("close_qr_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_qr_modal, false)
     |> assign(:qr_code_svg, nil)
     |> assign(:qr_config, nil)
     |> assign(:qr_config_name, nil)}
  end

  # Helper functions for the template

  # Safely parse a user-supplied id param. Rejects non-integer/garbage input
  # (e.g. "abc", "1; drop", "") so it can't crash the LiveView with an
  # ArgumentError from String.to_integer/1.
  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(value) when is_integer(value), do: {:ok, value}
  defp parse_id(_), do: :error

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

  defp config_protocol_label(config), do: VPN.server_protocol_label(config.vpn_server)

  defp wireguard_config?(config), do: VPN.server_protocol(config.vpn_server) == "wireguard"

  defp shadowsocks_port(config), do: VPN.shadowsocks_port(config)

  defp qr_help_text(config) do
    if is_nil(config) or wireguard_config?(config) do
      gettext("Scan this code with the WireGuard mobile app")
    else
      gettext("Scan this code with your Shadowsocks client")
    end
  end

  defp qr_steps(config) do
    if is_nil(config) or wireguard_config?(config) do
      [
        gettext("Open WireGuard app"),
        gettext("Tap '+' and select 'Create from QR code'"),
        gettext("Scan this code")
      ]
    else
      [
        gettext("Open your Shadowsocks client"),
        gettext("Choose the QR code or scan import option"),
        gettext("Scan this code")
      ]
    end
  end
end
