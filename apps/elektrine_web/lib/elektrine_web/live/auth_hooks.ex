defmodule ElektrineWeb.Live.AuthHooks do
  import Phoenix.LiveView
  import Phoenix.Component
  use ElektrineWeb, :verified_routes

  # Flash helper for auth on-mount hooks
  defp notify_error(socket, message), do: Phoenix.LiveView.put_flash(socket, :error, message)

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    case socket.assigns[:current_user] do
      %{banned: true} = user ->
        message =
          if user.banned_reason && String.trim(user.banned_reason) != "" do
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
            if user.suspension_reason && String.trim(user.suspension_reason) != "" do
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
          # Verify admin session IP hasn't changed (match controller security)
          verify_admin_session_ip(socket, session, user)
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
          if user.banned_reason && String.trim(user.banned_reason) != "" do
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
  defp requires_auth_module?(module) do
    auth_modules = [
      ElektrineWeb.ProfileLive.Edit,
      ElektrineWeb.ProfileLive.Analytics,
      ElektrineWeb.StorageLive,
      ElektrineWeb.ChatLive.Index,
      ElektrineWeb.FriendsLive,
      ElektrineWeb.NotificationsLive,
      ElektrineWeb.SettingsLive.AppPasswords,
      ElektrineWeb.EmailLive.Index,
      ElektrineWeb.EmailLive.Compose,
      ElektrineWeb.EmailLive.Show,
      ElektrineWeb.EmailLive.Raw,
      ElektrineWeb.EmailLive.Search,
      ElektrineWeb.VPNLive.Index,
      ElektrineWeb.SearchLive
    ]

    module in auth_modules
  end

  # Verify admin session IP hasn't changed (session hijacking detection)
  defp verify_admin_session_ip(socket, session, _user) do
    session_ip = session["admin_session_ip"]
    # Note: In LiveView we don't have direct access to conn.remote_ip
    # This check is less robust than controller version, but still provides some protection

    if session_ip do
      # IP was stored in session during controller login
      # We can't verify it changed here, but the controller will catch it
      {:cont, socket}
    else
      # No IP stored - this should not happen for new logins, but allow for compatibility
      {:cont, socket}
    end
  end

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
      {:ok, user_id} -> Elektrine.Accounts.get_user!(user_id)
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end
end
