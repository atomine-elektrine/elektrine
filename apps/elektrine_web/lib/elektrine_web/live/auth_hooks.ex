defmodule ElektrineWeb.Live.AuthHooks do
  @moduledoc false
  import Phoenix.LiveView
  import Phoenix.Component
  use ElektrineWeb, :verified_routes

  alias Elektrine.Accounts
  alias ElektrineWeb.AdminSecurity

  # These pages live in the shared :main live_session for seamless navigation,
  # so authentication must be enforced explicitly during on_mount.
  @authenticated_live_modules [
    ElektrineWeb.ChatLive.Index,
    ElektrineWeb.ContactsLive.Index,
    ElektrineWeb.EmailLive.Compose,
    ElektrineWeb.EmailLive.Index,
    ElektrineWeb.EmailLive.Raw,
    ElektrineWeb.EmailLive.Search,
    ElektrineWeb.EmailLive.Settings,
    ElektrineWeb.EmailLive.Show,
    ElektrineWeb.FriendsLive,
    ElektrineWeb.ListLive.Index,
    ElektrineWeb.ListLive.Show,
    ElektrineWeb.NotificationsLive,
    ElektrineWeb.OverviewLive.Index,
    ElektrineWeb.ProfileLive.Analytics,
    ElektrineWeb.ProfileLive.Domains,
    ElektrineWeb.ProfileLive.Edit,
    ElektrineWeb.SearchLive,
    ElektrineWeb.SettingsLive.AppPasswords,
    ElektrineWeb.SettingsLive.DeleteAccount,
    ElektrineWeb.SettingsLive.EditPassword,
    ElektrineWeb.SettingsLive.PasskeyManage,
    ElektrinePasswordManagerWeb.VaultLive,
    ElektrineWeb.SettingsLive.RSS,
    ElektrineWeb.SettingsLive.TwoFactorManage,
    ElektrineWeb.SettingsLive.TwoFactorSetup,
    ElektrineWeb.StorageLive,
    ElektrineWeb.UserSettingsLive,
    ElektrineWeb.VPNLive.Index
  ]

  @admin_read_only_events MapSet.new([
                            "clear_search",
                            "close_modal",
                            "close_report_modal",
                            "filter",
                            "filter_change",
                            "instances_next_page",
                            "instances_prev_page",
                            "load_more",
                            "next_page",
                            "prev_page",
                            "refresh",
                            "search",
                            "search_user",
                            "set_filter_status",
                            "show_add_block_modal",
                            "show_add_modal",
                            "show_policy_modal",
                            "switch_tab",
                            "sync_policy_form",
                            "update_new_domain",
                            "update_new_reason",
                            "update_policy_form",
                            "view_report",
                            "view_reported_item",
                            "actors_next_page",
                            "actors_prev_page"
                          ])

  # Flash helper for auth on-mount hooks
  defp notify_error(socket, message), do: Phoenix.LiveView.put_flash(socket, :error, message)

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    case socket.assigns[:current_user] do
      %{banned: true} = user ->
        message =
          if Elektrine.Strings.present?(user.banned_reason) do
            "Your account has been banned. Reason: #{user.banned_reason}"
          else
            "Your account has been banned. Please contact support if you believe this is an error."
          end

        socket =
          socket
          |> notify_error(message)
          |> redirect(to: ~p"/logout")

        {:halt, socket}

      %{suspended: true} = user ->
        if Elektrine.Accounts.user_suspended?(user) do
          base_message =
            if user.suspended_until do
              "Your account is suspended until #{Calendar.strftime(user.suspended_until, "%B %d, %Y")}"
            else
              "Your account is suspended"
            end

          message =
            if Elektrine.Strings.present?(user.suspension_reason) do
              "#{base_message}. Reason: #{user.suspension_reason}"
            else
              "#{base_message}. Please contact support if you believe this is an error."
            end

          socket =
            socket
            |> notify_error(message)
            |> redirect(to: ~p"/logout")

          {:halt, socket}
        else
          # Suspension has expired, auto-unsuspend (match controller behavior)
          {:ok, _} = Elektrine.Accounts.unsuspend_user(user)
          {:cont, socket}
        end

      %{} = _user ->
        {:cont, socket}

      nil ->
        socket =
          socket
          |> notify_error("You must log in to access this live page.")
          |> redirect(to: ~p"/login")

        {:halt, socket}
    end
  end

  def on_mount(:maybe_authenticated_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    # Check if this LiveView module requires authentication
    view_module = socket.view

    if requires_auth_module?(view_module) && is_nil(socket.assigns[:current_user]) do
      socket =
        socket
        |> notify_error("You must log in to access this page.")
        |> redirect(to: ~p"/login")

      {:halt, socket}
    else
      {:cont, socket}
    end
  end

  def on_mount(:require_admin_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    case socket.assigns[:current_user] do
      %{is_admin: true, banned: false} = user ->
        # Check if suspended
        if user.suspended && Elektrine.Accounts.user_suspended?(user) do
          # Return 404 to hide admin routes (match controller behavior)
          socket = socket |> redirect(to: ~p"/")
          {:halt, socket}
        else
          peer_data = get_connect_info(socket, :peer_data)

          with :ok <- verify_live_admin_session_ip(session, peer_data),
               :ok <- AdminSecurity.validate_live_admin_session(session, user) do
            socket =
              socket
              |> assign(:admin_session_ip, AdminSecurity.session_admin_ip(session))
              |> assign(:admin_peer_ip, peer_ip(peer_data))
              |> assign_admin_security_metadata(session)
              |> attach_hook(
                :enforce_admin_event_security,
                :handle_event,
                &enforce_admin_live_event_security/3
              )

            {:cont, socket}
          else
            {:error, reason} ->
              socket =
                socket
                |> notify_error(AdminSecurity.error_message(reason))
                |> redirect(to: AdminSecurity.elevation_redirect_path("/pripyat"))

              {:halt, socket}
          end
        end

      %{banned: true} ->
        # Banned users get redirected (match controller behavior)
        socket = socket |> redirect(to: ~p"/")
        {:halt, socket}

      _ ->
        # All other cases (not logged in, not admin) - hide admin routes
        socket = socket |> redirect(to: ~p"/")
        {:halt, socket}
    end
  end

  @doc """
  Requires user to have an active subscription for a product.
  Use with: on_mount {ElektrineWeb.Live.AuthHooks, {:require_subscription, "vpn"}}
  """
  def on_mount({:require_subscription, product}, _params, session, socket) do
    socket = mount_current_user(socket, session)

    case socket.assigns[:current_user] do
      nil ->
        socket =
          socket
          |> notify_error("You must log in to access this page.")
          |> redirect(to: ~p"/login")

        {:halt, socket}

      %{banned: true} = user ->
        message =
          if Elektrine.Strings.present?(user.banned_reason) do
            "Your account has been banned. Reason: #{user.banned_reason}"
          else
            "Your account has been banned."
          end

        socket =
          socket
          |> notify_error(message)
          |> redirect(to: ~p"/logout")

        {:halt, socket}

      user ->
        if Elektrine.Subscriptions.has_access?(user, product) do
          {:cont, socket}
        else
          socket =
            socket
            |> redirect(to: ~p"/subscribe/#{product}")

          {:halt, socket}
        end
    end
  end

  # LiveView modules that require authentication
  defp requires_auth_module?(module), do: module in @authenticated_live_modules

  defp verify_live_admin_session_ip(session, peer_data) do
    session_ip = AdminSecurity.session_admin_ip(session)
    current_ip = peer_ip(peer_data)

    cond do
      is_nil(session_ip) -> :ok
      is_nil(current_ip) -> {:error, :admin_ip_changed}
      session_ip == current_ip -> :ok
      true -> {:error, :admin_ip_changed}
    end
  end

  defp assign_admin_security_metadata(socket, session) do
    socket
    |> assign(:admin_auth_method, session["admin_auth_method"])
    |> assign(:admin_access_expires_at, parse_session_int(session["admin_access_expires_at"]))
    |> assign(:admin_elevated_until, parse_session_int(session["admin_elevated_until"]))
    |> assign(:admin_last_resign_at, parse_session_int(session["admin_last_resign_at"]))
  end

  defp enforce_admin_live_event_security(event, _params, socket) do
    now = System.system_time(:second)
    auth_method = socket.assigns[:admin_auth_method]
    access_expires_at = socket.assigns[:admin_access_expires_at] || 0
    elevated_until = socket.assigns[:admin_elevated_until] || 0

    passkey_required? =
      Application.get_env(:elektrine, :admin_security, []) |> Keyword.get(:require_passkey, true)

    passkey_ok = not passkey_required? or auth_method == "passkey"
    ttl_ok = access_expires_at >= now and elevated_until >= now

    confirmation_ok =
      recent_admin_confirmation?(socket.assigns[:admin_last_resign_at]) ||
        not requires_recent_admin_confirmation?(event)

    ip_ok =
      case {socket.assigns[:admin_session_ip], socket.assigns[:admin_peer_ip]} do
        {nil, _} ->
          true

        {session_ip, peer_ip} when is_binary(session_ip) and is_binary(peer_ip) ->
          session_ip == peer_ip

        _ ->
          false
      end

    if passkey_ok and ttl_ok and confirmation_ok and ip_ok do
      {:cont, socket}
    else
      reason =
        cond do
          not ip_ok -> :admin_ip_changed
          not confirmation_ok -> :action_grant_required
          true -> :elevation_required
        end

      socket =
        socket
        |> notify_error(AdminSecurity.error_message(reason))
        |> push_navigate(to: AdminSecurity.elevation_redirect_path("/pripyat"))

      {:halt, socket}
    end
  end

  defp requires_recent_admin_confirmation?(event) when is_binary(event) do
    not MapSet.member?(@admin_read_only_events, event)
  end

  defp requires_recent_admin_confirmation?(_event), do: true

  defp recent_admin_confirmation?(last_resign_at) when is_integer(last_resign_at) do
    System.system_time(:second) - last_resign_at <= AdminSecurity.action_grant_ttl_seconds()
  end

  defp recent_admin_confirmation?(_), do: false

  defp peer_ip(%{address: address}) do
    address |> :inet.ntoa() |> to_string()
  rescue
    _ -> nil
  end

  defp peer_ip(_), do: nil

  defp parse_session_int(value) when is_integer(value), do: value

  defp parse_session_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_session_int(_), do: nil

  defp mount_current_user(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_user, fn ->
        if user_token = session["user_token"] do
          fetch_user_by_token(user_token)
        end
      end)

    # Add impersonation status
    socket = assign(socket, :is_impersonating, session["impersonating_admin_id"] != nil)

    # Load notification count and subscribe to updates if user is authenticated
    if socket.assigns.current_user do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(
          Elektrine.PubSub,
          "user:#{socket.assigns.current_user.id}:notification_count"
        )

        # Track daily visit for trust level system (only on connected socket, once per session)
        session_key = "visit_tracked_#{Date.utc_today()}"

        unless session[session_key] do
          # Side-effect (tracking): skip in tests.
          Elektrine.Async.start(fn ->
            Elektrine.Accounts.TrustLevel.track_visit(socket.assigns.current_user.id)
          end)
        end
      end

      count = Elektrine.Notifications.get_unread_count(socket.assigns.current_user.id)
      assign(socket, :notification_count, count)
    else
      socket
    end
  end

  # Helper function to fetch user by token (copied from user_auth.ex)
  defp fetch_user_by_token(token) do
    case Phoenix.Token.verify(ElektrineWeb.Endpoint, "user auth", token,
           max_age: 60 * 60 * 24 * 60
         ) do
      {:ok, claims} -> claims |> session_user_id() |> fetch_user_for_claims(claims)
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  defp session_user_id(%{"user_id" => user_id}) when is_integer(user_id), do: user_id
  defp session_user_id(_claims), do: nil

  defp fetch_user_for_claims(nil, _claims), do: nil

  defp fetch_user_for_claims(user_id, claims) do
    user = Accounts.get_user!(user_id)

    if session_claims_valid?(user, claims) do
      user
    else
      nil
    end
  end

  defp session_claims_valid?(user, %{
         "password_changed_at" => changed_at,
         "auth_valid_after" => valid_after
       }) do
    password_changed_at_unix(user) == changed_at and auth_valid_after_unix(user) == valid_after
  end

  defp session_claims_valid?(_user, _claims), do: false

  defp password_changed_at_unix(%{last_password_change: %DateTime{} = changed_at}) do
    DateTime.to_unix(changed_at)
  end

  defp password_changed_at_unix(_user), do: nil

  defp auth_valid_after_unix(%{auth_valid_after: %DateTime{} = valid_after}) do
    DateTime.to_unix(valid_after)
  end

  defp auth_valid_after_unix(_user), do: nil
end
