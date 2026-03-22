defmodule ElektrineWeb.UserSettingsLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Accounts
  alias Elektrine.Accounts.RecoveryEmailVerification
  alias Elektrine.Bluesky.Managed, as: BlueskyManaged
  alias Elektrine.Developer
  alias Elektrine.Developer.ApiToken
  alias Elektrine.Platform.Modules
  alias Elektrine.RSS
  alias ElektrineWeb.Platform.Integrations
  on_mount({ElektrineWeb.Live.AuthHooks, :require_authenticated_user})
  @default_tab "profile"
  @setting_tabs [
    {"profile", "hero-user", :default},
    {"security", "hero-shield-check", :default},
    {"privacy", "hero-lock-closed", :default},
    {"preferences", "hero-cog-6-tooth", :default},
    {"notifications", "hero-bell", :default},
    {"federation", "hero-globe-alt", :default},
    {"timeline", "hero-queue-list", :default},
    {"email", "hero-envelope", :default},
    {"developer", "hero-code-bracket", :default},
    {"danger", "hero-exclamation-triangle", :danger}
  ]
  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    invite_code_policy = Accounts.self_service_invite_policy()

    avatar_limit =
      if user.is_admin do
        50 * 1024 * 1024
      else
        5 * 1024 * 1024
      end

    avatar_upload_limit_text =
      if user.is_admin do
        "50MB"
      else
        "5MB"
      end

    {:ok,
     socket
     |> assign(:page_title, "Account Settings")
     |> assign(:user, user)
     |> assign(:avatar_upload_limit_text, avatar_upload_limit_text)
     |> assign(:invite_codes_enabled, Elektrine.System.invite_codes_enabled?())
     |> assign(:invite_code_policy, invite_code_policy)
     |> assign(:can_create_invite_codes, Accounts.user_can_create_invite_codes?(user))
     |> assign(:user_invite_codes, [])
     |> assign(
       :bluesky_managed_enabled,
       Application.get_env(:elektrine, :bluesky, []) |> Keyword.get(:managed_enabled, false)
     )
     |> assign(:changeset, Accounts.change_user(user, %{}))
     |> assign(:handle_changeset, Accounts.User.handle_changeset(user, %{}))
     |> assign(:loading_profile, true)
     |> assign(:loading_security, true)
     |> assign(:loading_timeline, true)
     |> assign(:loading_developer, true)
     |> assign(:loading_danger, true)
     |> assign(:pending_deletion, nil)
     |> assign(:email_restriction_status, %{restricted: false})
     |> assign(:rss_subscriptions, [])
     |> assign(:new_feed_url, "")
     |> assign(:adding_feed, false)
     |> assign(:rss_error, nil)
     |> assign(:api_tokens, [])
     |> assign(:webhooks, [])
     |> assign(:recent_webhook_deliveries, [])
     |> assign(:webhook_deliveries_by_webhook, %{})
     |> assign(:pending_exports, [])
     |> assign(:show_create_token_modal, false)
     |> assign(:show_create_webhook_modal, false)
     |> assign(:token_form_params, default_token_form_params())
     |> assign(:token_form, to_form(default_token_form_params(), as: :token))
     |> assign(:webhook_form, to_form(%{"name" => "", "url" => "", "events" => []}, as: :webhook))
     |> assign(:new_token, nil)
     |> assign(:revealed_webhook_secret, nil)
     |> Integrations.init_user_settings_email()
     |> allow_upload(:avatar,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 1,
       max_file_size: avatar_limit,
       auto_upload: true
     )}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _url, socket) do
    selected_tab = normalize_selected_tab(tab)
    socket = assign(socket, :selected_tab, selected_tab)

    if connected?(socket) do
      send(self(), {:load_tab_data, selected_tab})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    socket = assign(socket, :selected_tab, @default_tab)

    if connected?(socket) do
      send(self(), {:load_tab_data, @default_tab})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:load_tab_data, tab}, socket) do
    socket = load_tab_data(socket, tab)
    {:noreply, socket}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp load_tab_data(socket, "profile") do
    if socket.assigns.loading_profile do
      user = socket.assigns.user
      pending_deletion = Accounts.get_pending_deletion_request(user)
      user_invite_codes = Accounts.list_user_invite_codes(user.id)

      socket
      |> assign(:pending_deletion, pending_deletion)
      |> assign(:user_invite_codes, user_invite_codes)
      |> assign(:loading_profile, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "security") do
    if socket.assigns.loading_security do
      user = socket.assigns.user
      email_restriction_status = Integrations.email_restriction_status(user.id)

      socket
      |> assign(:email_restriction_status, email_restriction_status)
      |> assign(:loading_security, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "email") do
    if socket.assigns.loading_email do
      Integrations.load_user_settings_email(socket)
    else
      socket
    end
  end

  defp load_tab_data(socket, "timeline") do
    if socket.assigns.loading_timeline do
      user = socket.assigns.user
      rss_subscriptions = RSS.list_subscriptions(user.id)
      socket |> assign(:rss_subscriptions, rss_subscriptions) |> assign(:loading_timeline, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "developer") do
    if socket.assigns.loading_developer do
      socket
      |> assign_developer_state(socket.assigns.user.id)
      |> assign(:loading_developer, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "danger") do
    if socket.assigns.loading_danger do
      user = socket.assigns.user
      pending_deletion = Accounts.get_pending_deletion_request(user)
      socket |> assign(:pending_deletion, pending_deletion) |> assign(:loading_danger, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, _tab) do
    socket
  end

  defp assign_developer_state(socket, user_id) do
    api_tokens_task = Task.async(fn -> Developer.list_api_tokens(user_id) end)
    webhooks_task = Task.async(fn -> Developer.list_webhooks(user_id) end)
    pending_exports_task = Task.async(fn -> Developer.get_pending_exports(user_id) end)
    deliveries_task = Task.async(fn -> Developer.list_webhook_deliveries(user_id, limit: 30) end)

    api_tokens = Task.await(api_tokens_task)
    webhooks = Task.await(webhooks_task)
    pending_exports = Task.await(pending_exports_task)
    deliveries = Task.await(deliveries_task)

    deliveries_by_webhook =
      deliveries
      |> Enum.group_by(& &1.webhook_id)
      |> Map.new(fn {webhook_id, webhook_deliveries} ->
        {webhook_id, Enum.sort_by(webhook_deliveries, & &1.inserted_at, {:desc, NaiveDateTime})}
      end)

    socket
    |> assign(:api_tokens, api_tokens)
    |> assign(:webhooks, webhooks)
    |> assign(:pending_exports, pending_exports)
    |> assign(:recent_webhook_deliveries, deliveries)
    |> assign(:webhook_deliveries_by_webhook, deliveries_by_webhook)
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    tab = normalize_selected_tab(tab)
    {:noreply, push_patch(socket, to: ~p"/account?tab=#{tab}")}
  end

  @impl true
  def handle_event("cancel_avatar_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  @impl true
  def handle_event("validate", %{"_target" => ["avatar"]}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"_target" => ["user", _field]}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    filtered_params =
      Map.take(user_params, [
        "display_name",
        "recovery_email",
        "handle",
        "allow_group_adds_from",
        "allow_direct_messages_from",
        "allow_mentions_from",
        "allow_calls_from",
        "allow_friend_requests_from",
        "profile_visibility",
        "default_post_visibility",
        "notify_on_new_follower",
        "notify_on_direct_message",
        "notify_on_mention",
        "notify_on_reply",
        "notify_on_like",
        "notify_on_email_received",
        "notify_on_discussion_reply",
        "notify_on_comment",
        "locale",
        "timezone",
        "time_format",
        "email_signature",
        "activitypub_manually_approve_followers"
      ])

    checkbox_fields = checkbox_fields_for_tab(socket.assigns.selected_tab)

    params_with_checkboxes =
      Enum.reduce(checkbox_fields, filtered_params, fn field, acc ->
        case Map.get(acc, field) do
          "true" -> Map.put(acc, field, true)
          nil -> Map.put(acc, field, false)
          _ -> acc
        end
      end)

    final_params =
      case Map.get(params_with_checkboxes, "timezone") do
        "" -> Map.put(params_with_checkboxes, "timezone", nil)
        _ -> params_with_checkboxes
      end

    changeset =
      socket.assigns.user |> Accounts.change_user(final_params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl true
  def handle_event("save", params, socket) when params == %{} do
    handle_event("save", %{"user" => %{}}, socket)
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    {completed, in_progress} = uploaded_entries(socket, :avatar)

    if in_progress != [] do
      {:noreply, put_flash(socket, :error, "Please wait for the upload to complete")}
    else
      user_params_with_avatar =
        if completed != [] do
          consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
            case Elektrine.Uploads.upload_avatar(
                   %Plug.Upload{
                     filename: entry.client_name,
                     path: path,
                     content_type: entry.client_type
                   },
                   socket.assigns.user.id
                 ) do
              {:ok, metadata} ->
                updated_params =
                  user_params
                  |> Map.put("avatar", metadata.key)
                  |> Map.put("avatar_size", metadata.size)

                {:ok, updated_params}

              {:error, _reason} ->
                {:ok, user_params}
            end
          end)
          |> case do
            [updated_params] -> updated_params
            [] -> user_params
          end
        else
          user_params
        end

      save_user_settings(socket, user_params_with_avatar)
    end
  end

  @impl true
  def handle_event("enable_bluesky_managed", %{"current_password" => current_password}, socket) do
    user = socket.assigns.user

    result =
      if user.bluesky_enabled do
        BlueskyManaged.reconnect_for_user(user, current_password)
      else
        case BlueskyManaged.reconnect_for_user(user, current_password) do
          {:ok, _result} = ok ->
            ok

          {:error, :missing_identifier} ->
            BlueskyManaged.enable_for_user(user, current_password)

          {:error, {:create_session_failed, _status}} ->
            BlueskyManaged.enable_for_user(user, current_password)

          {:error, _reason} = error ->
            error
        end
      end

    case result do
      {:ok, %{user: updated_user}} ->
        refreshed_user = Accounts.get_user!(updated_user.id)

        {:noreply,
         socket
         |> assign(:user, refreshed_user)
         |> assign(:changeset, Accounts.change_user(refreshed_user, %{}))
         |> notify_success("Bluesky managed account connected")}

      {:error, reason} ->
        {:noreply, notify_error(socket, bluesky_managed_error_message(reason))}
    end
  end

  @impl true
  def handle_event("enable_bluesky_managed", _params, socket) do
    {:noreply, notify_error(socket, "Current password is required")}
  end

  @impl true
  def handle_event("reconnect_bluesky_managed", %{"current_password" => current_password}, socket) do
    user = socket.assigns.user

    case BlueskyManaged.reconnect_for_user(user, current_password) do
      {:ok, %{user: updated_user}} ->
        refreshed_user = Accounts.get_user!(updated_user.id)

        {:noreply,
         socket
         |> assign(:user, refreshed_user)
         |> assign(:changeset, Accounts.change_user(refreshed_user, %{}))
         |> notify_success("Bluesky managed account reconnected")}

      {:error, reason} ->
        {:noreply, notify_error(socket, bluesky_managed_error_message(reason))}
    end
  end

  @impl true
  def handle_event("reconnect_bluesky_managed", _params, socket) do
    {:noreply, notify_error(socket, "Current password is required")}
  end

  @impl true
  def handle_event(
        "disconnect_bluesky_managed",
        %{"current_password" => current_password},
        socket
      ) do
    user = socket.assigns.user

    case BlueskyManaged.disconnect_for_user(user, current_password) do
      {:ok, updated_user} ->
        refreshed_user = Accounts.get_user!(updated_user.id)

        {:noreply,
         socket
         |> assign(:user, refreshed_user)
         |> assign(:changeset, Accounts.change_user(refreshed_user, %{}))
         |> notify_success("Bluesky managed account disconnected")}

      {:error, reason} ->
        {:noreply, notify_error(socket, bluesky_managed_error_message(reason))}
    end
  end

  @impl true
  def handle_event("disconnect_bluesky_managed", _params, socket) do
    {:noreply, notify_error(socket, "Current password is required")}
  end

  def handle_event("toggle_subscription", params, socket),
    do: {:noreply, handle_email_settings_event("toggle_subscription", params, socket)}

  @impl true
  def handle_event("unsubscribe_all", params, socket),
    do: {:noreply, handle_email_settings_event("unsubscribe_all", params, socket)}

  @impl true
  def handle_event("resubscribe_all", params, socket),
    do: {:noreply, handle_email_settings_event("resubscribe_all", params, socket)}

  @impl true
  def handle_event("send_recovery_verification", _params, socket) do
    user = socket.assigns.current_user

    case RecoveryEmailVerification.send_verification_email(user.id) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:changeset, Accounts.change_user(updated_user, %{}))
         |> notify_info("Verification email sent to your recovery email address.")}

      {:error, :already_verified} ->
        {:noreply, socket |> notify_info("Your recovery email is already verified.")}

      {:error, :no_recovery_email} ->
        {:noreply, socket |> notify_error("Please add a recovery email address first.")}

      {:error, _reason} ->
        {:noreply, socket |> notify_error("Failed to send verification email. Please try again.")}
    end
  end

  @impl true
  def handle_event("create_invite_code", %{"invite" => invite_params}, socket) do
    user = socket.assigns.current_user

    case Accounts.create_self_service_invite_code(user, invite_params) do
      {:ok, _invite_code} ->
        {:noreply,
         socket
         |> refresh_user_invite_codes()
         |> notify_success("Invite code created")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         notify_error(
           socket,
           "Could not create invite code: #{format_changeset_errors(changeset)}"
         )}

      {:error, reason} ->
        {:noreply, notify_error(socket, invite_code_error_message(reason, socket))}
    end
  end

  @impl true
  def handle_event("deactivate_invite_code", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Integer.parse(id) do
      {invite_code_id, ""} ->
        case Accounts.deactivate_self_service_invite_code(user, invite_code_id) do
          {:ok, _invite_code} ->
            {:noreply,
             socket
             |> refresh_user_invite_codes()
             |> notify_info("Invite code deactivated")}

          {:error, :not_found} ->
            {:noreply, notify_error(socket, "Invite code not found")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             notify_error(
               socket,
               "Could not deactivate invite code: #{format_changeset_errors(changeset)}"
             )}

          {:error, reason} ->
            {:noreply, notify_error(socket, invite_code_error_message(reason, socket))}
        end

      _ ->
        {:noreply, notify_error(socket, "Invalid invite code")}
    end
  end

  @impl true
  def handle_event("upload_pgp_key", params, socket),
    do: {:noreply, handle_email_settings_event("upload_pgp_key", params, socket)}

  @impl true
  def handle_event("delete_pgp_key", params, socket),
    do: {:noreply, handle_email_settings_event("delete_pgp_key", params, socket)}

  @impl true
  def handle_event("private_mailbox_setup", params, socket),
    do: {:noreply, handle_email_settings_event("private_mailbox_setup", params, socket)}

  @impl true
  def handle_event("enable_private_mailbox", params, socket),
    do: {:noreply, handle_email_settings_event("enable_private_mailbox", params, socket)}

  @impl true
  def handle_event("disable_private_mailbox", params, socket),
    do: {:noreply, handle_email_settings_event("disable_private_mailbox", params, socket)}

  @impl true
  def handle_event("add_rss_feed", %{"url" => url}, socket) do
    url = String.trim(url)

    if url == "" do
      {:noreply, assign(socket, :rss_error, "Please enter a feed URL")}
    else
      socket = assign(socket, :adding_feed, true)

      case RSS.subscribe(socket.assigns.current_user.id, url) do
        {:ok, subscription} ->
          %{feed_id: subscription.feed_id}
          |> Elektrine.RSS.FetchFeedWorker.new()
          |> Elektrine.JobQueue.insert()

          {:noreply,
           socket
           |> assign(:rss_subscriptions, [subscription | socket.assigns.rss_subscriptions])
           |> assign(:new_feed_url, "")
           |> assign(:adding_feed, false)
           |> assign(:rss_error, nil)
           |> notify_info("Feed added! It will be fetched shortly.")}

        {:error, changeset} ->
          error =
            case changeset.errors[:feed_id] do
              {_, constraint: :unique, constraint_name: _} ->
                "You're already subscribed to this feed"

              _ ->
                "Failed to add feed. Please check the URL."
            end

          {:noreply, socket |> assign(:adding_feed, false) |> assign(:rss_error, error)}
      end
    end
  end

  @impl true
  def handle_event("update_feed_url", %{"url" => url}, socket) do
    {:noreply, assign(socket, :new_feed_url, url)}
  end

  @impl true
  def handle_event("remove_rss_feed", %{"feed_id" => feed_id}, socket) do
    feed_id = String.to_integer(feed_id)

    case RSS.unsubscribe(socket.assigns.current_user.id, feed_id) do
      {:ok, _} ->
        subscriptions = Enum.reject(socket.assigns.rss_subscriptions, &(&1.feed_id == feed_id))

        {:noreply,
         socket
         |> assign(:rss_subscriptions, subscriptions)
         |> notify_info("Unsubscribed from feed")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to unsubscribe")}
    end
  end

  @impl true
  def handle_event("toggle_rss_timeline", %{"subscription_id" => subscription_id}, socket) do
    subscription_id = String.to_integer(subscription_id)
    subscription = Enum.find(socket.assigns.rss_subscriptions, &(&1.id == subscription_id))

    if subscription do
      new_value = !subscription.show_in_timeline

      case RSS.update_subscription(subscription, %{show_in_timeline: new_value}) do
        {:ok, updated} ->
          subscriptions =
            Enum.map(socket.assigns.rss_subscriptions, fn s ->
              if s.id == subscription_id do
                updated
              else
                s
              end
            end)

          {:noreply, assign(socket, :rss_subscriptions, subscriptions)}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to update subscription")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("show_create_token_modal", _params, socket) do
    token_form_params = default_token_form_params()

    {:noreply,
     socket
     |> assign(:show_create_token_modal, true)
     |> assign(:new_token, nil)
     |> assign(:token_form_params, token_form_params)
     |> assign(:token_form, to_form(token_form_params, as: :token))}
  end

  @impl true
  def handle_event("close_token_modal", _params, socket) do
    token_form_params = default_token_form_params()

    {:noreply,
     socket
     |> assign(:show_create_token_modal, false)
     |> assign(:new_token, nil)
     |> assign(:token_form_params, token_form_params)
     |> assign(:token_form, to_form(token_form_params, as: :token))}
  end

  @impl true
  def handle_event("token_form_changed", %{"token" => token_params}, socket) do
    token_form_params = normalize_token_form_params(token_params)

    {:noreply,
     socket
     |> assign(:token_form_params, token_form_params)
     |> assign(:token_form, to_form(token_form_params, as: :token))}
  end

  @impl true
  def handle_event("create_token", %{"token" => token_params}, socket) do
    user = socket.assigns.current_user
    token_form_params = normalize_token_form_params(token_params)
    scopes = resolve_token_scopes(token_form_params)

    case parse_token_expiration(token_form_params["expires_in"]) do
      {:ok, expires_at} ->
        attrs = %{name: token_form_params["name"], scopes: scopes, expires_at: expires_at}

        case Developer.create_api_token(user.id, attrs) do
          {:ok, token} ->
            {:noreply,
             socket
             |> assign(:new_token, token.token)
             |> assign(:token_form_params, token_form_params)
             |> assign(:token_form, to_form(token_form_params, as: :token))
             |> assign_developer_state(user.id)}

          {:error, changeset} ->
            error_msg = changeset_error_to_string(changeset)

            {:noreply,
             socket
             |> assign(:token_form_params, token_form_params)
             |> assign(:token_form, to_form(token_form_params, as: :token))
             |> notify_error("Failed to create token: #{error_msg}")}
        end

      :error ->
        {:noreply,
         socket
         |> assign(:token_form_params, token_form_params)
         |> assign(:token_form, to_form(token_form_params, as: :token))
         |> notify_error("Invalid token expiration. Use 30, 90, or 365 days.")}
    end
  end

  @impl true
  def handle_event("revoke_token", %{"id" => token_id}, socket) do
    user = socket.assigns.current_user

    case Integer.parse(token_id) do
      {id, ""} ->
        case Developer.revoke_api_token(user.id, id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign_developer_state(user.id)
             |> notify_success("Token revoked successfully")}

          {:error, :not_found} ->
            {:noreply, notify_error(socket, "Token not found")}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to revoke token")}
        end

      _ ->
        {:noreply, notify_error(socket, "Invalid token id")}
    end
  end

  @impl true
  def handle_event("duplicate_token", %{"id" => token_id}, socket) do
    user = socket.assigns.current_user

    case Integer.parse(token_id) do
      {id, ""} ->
        case Developer.get_api_token(user.id, id) do
          nil ->
            {:noreply, notify_error(socket, "Token not found")}

          token ->
            token_form_params = token_form_params_for_existing_token(token)

            {:noreply,
             socket
             |> assign(:show_create_token_modal, true)
             |> assign(:new_token, nil)
             |> assign(:token_form_params, token_form_params)
             |> assign(:token_form, to_form(token_form_params, as: :token))}
        end

      _ ->
        {:noreply, notify_error(socket, "Invalid token id")}
    end
  end

  @impl true
  def handle_event("show_create_webhook_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_webhook_modal, true)
     |> assign(:webhook_form, to_form(%{"name" => "", "url" => "", "events" => []}, as: :webhook))}
  end

  @impl true
  def handle_event("close_webhook_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_webhook_modal, false)}
  end

  @impl true
  def handle_event("create_webhook", %{"webhook" => webhook_params}, socket) do
    user = socket.assigns.current_user

    events =
      case Map.get(webhook_params, "events", []) do
        nil -> []
        events when is_list(events) -> events
        event when is_binary(event) -> [event]
        _ -> []
      end

    attrs = %{name: webhook_params["name"], url: webhook_params["url"], events: events}

    case Developer.create_webhook(user.id, attrs) do
      {:ok, webhook} ->
        {:noreply,
         socket
         |> assign_developer_state(user.id)
         |> assign(:show_create_webhook_modal, false)
         |> assign(
           :revealed_webhook_secret,
           %{webhook_id: webhook.id, name: webhook.name, secret: webhook.secret}
         )
         |> assign(
           :webhook_form,
           to_form(%{"name" => "", "url" => "", "events" => []}, as: :webhook)
         )
         |> notify_success("Webhook created successfully")}

      {:error, changeset} ->
        error_msg = changeset_error_to_string(changeset)

        {:noreply,
         socket
         |> assign(:webhook_form, to_form(%{changeset | action: :insert}, as: :webhook))
         |> notify_error("Failed to create webhook: #{error_msg}")}
    end
  end

  @impl true
  def handle_event("delete_webhook", %{"id" => webhook_id}, socket) do
    user = socket.assigns.current_user

    case Integer.parse(webhook_id) do
      {id, ""} ->
        case Developer.delete_webhook(user.id, id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign_developer_state(user.id)
             |> maybe_clear_revealed_webhook_secret(id)
             |> notify_success("Webhook deleted successfully")}

          {:error, :not_found} ->
            {:noreply, notify_error(socket, "Webhook not found")}

          {:error, _reason} ->
            {:noreply, notify_error(socket, "Failed to delete webhook")}
        end

      _ ->
        {:noreply, notify_error(socket, "Invalid webhook id")}
    end
  end

  @impl true
  def handle_event("test_webhook", %{"id" => webhook_id}, socket) do
    user = socket.assigns.current_user

    case Integer.parse(webhook_id) do
      {id, ""} ->
        case Developer.test_webhook(user.id, id) do
          {:ok, status} ->
            {:noreply,
             socket
             |> assign_developer_state(user.id)
             |> notify_success("Webhook test delivered (HTTP #{status})")}

          {:error, :not_found} ->
            {:noreply, notify_error(socket, "Webhook not found")}

          {:error, {:http_error, status}} ->
            {:noreply,
             socket
             |> assign_developer_state(user.id)
             |> notify_error("Webhook endpoint returned HTTP #{status}")}

          {:error, {:request_failed, reason}} ->
            {:noreply,
             socket
             |> assign_developer_state(user.id)
             |> notify_error("Webhook test failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, notify_error(socket, "Invalid webhook id")}
    end
  end

  @impl true
  def handle_event("rotate_webhook_secret", %{"id" => webhook_id}, socket) do
    user = socket.assigns.current_user

    case Integer.parse(webhook_id) do
      {id, ""} ->
        case Developer.rotate_webhook_secret(user.id, id) do
          {:ok, webhook} ->
            {:noreply,
             socket
             |> assign_developer_state(user.id)
             |> assign(
               :revealed_webhook_secret,
               %{webhook_id: webhook.id, name: webhook.name, secret: webhook.secret}
             )
             |> notify_success("Webhook secret rotated")}

          {:error, :not_found} ->
            {:noreply, notify_error(socket, "Webhook not found")}

          {:error, _reason} ->
            {:noreply, notify_error(socket, "Failed to rotate webhook secret")}
        end

      _ ->
        {:noreply, notify_error(socket, "Invalid webhook id")}
    end
  end

  @impl true
  def handle_event("replay_webhook_delivery", %{"id" => delivery_id}, socket) do
    user = socket.assigns.current_user

    case Integer.parse(delivery_id) do
      {id, ""} ->
        case Developer.replay_webhook_delivery(user.id, id) do
          {:ok, :queued} ->
            {:noreply,
             socket
             |> assign_developer_state(user.id)
             |> notify_success("Webhook delivery replay queued")}

          {:error, :not_found} ->
            {:noreply, notify_error(socket, "Webhook delivery not found")}

          {:error, {:enqueue_failed, _reason}} ->
            {:noreply, notify_error(socket, "Failed to queue webhook replay")}

          {:error, _reason} ->
            {:noreply, notify_error(socket, "Failed to replay webhook delivery")}
        end

      _ ->
        {:noreply, notify_error(socket, "Invalid delivery id")}
    end
  end

  @impl true
  def handle_event("close_webhook_secret_notice", _params, socket) do
    {:noreply, assign(socket, :revealed_webhook_secret, nil)}
  end

  @impl true
  def handle_event("export_data", %{"type" => export_type}, socket) do
    user = socket.assigns.current_user
    attrs = %{export_type: export_type, format: "json"}

    case Developer.create_export(user.id, attrs) do
      {:ok, export} ->
        %{export_id: export.id}
        |> Elektrine.Developer.ExportWorker.new()
        |> Elektrine.JobQueue.insert()

        {:noreply,
         socket
         |> assign_developer_state(user.id)
         |> notify_success("Export started. You'll be notified when it's ready.")}

      {:error, changeset} ->
        error_msg = changeset_error_to_string(changeset)
        {:noreply, notify_error(socket, "Failed to start export: #{error_msg}")}
    end
  end

  defp save_user_settings(socket, user_params_with_avatar) do
    {_handle_param, other_params} = Map.pop(user_params_with_avatar, "handle")

    other_params_sanitized =
      Map.drop(other_params, [
        "bluesky_enabled",
        "bluesky_identifier",
        "bluesky_app_password",
        "bluesky_pds_url"
      ])

    checkbox_fields = checkbox_fields_for_tab(socket.assigns.selected_tab)

    other_params_with_checkboxes =
      Enum.reduce(checkbox_fields, other_params_sanitized, fn field, acc ->
        case Map.get(acc, field) do
          "true" -> Map.put(acc, field, true)
          nil -> Map.put(acc, field, false)
          _ -> acc
        end
      end)

    params_with_timezone =
      case Map.get(other_params_with_checkboxes, "timezone") do
        "" -> Map.put(other_params_with_checkboxes, "timezone", nil)
        _ -> other_params_with_checkboxes
      end

    params_with_bluesky_password =
      case Map.get(params_with_timezone, "bluesky_app_password") do
        "" -> Map.delete(params_with_timezone, "bluesky_app_password")
        _ -> params_with_timezone
      end

    {recovery_email_param, final_params} = Map.pop(params_with_bluesky_password, "recovery_email")

    other_result =
      if map_size(final_params) > 0 do
        Accounts.update_user(socket.assigns.user, final_params)
      else
        {:ok, socket.assigns.user}
      end

    case other_result do
      {:ok, _updated_user} ->
        updated_user = Accounts.get_user!(socket.assigns.user.id)
        old_recovery_email = socket.assigns.user.recovery_email

        {final_user, message} =
          if recovery_email_param && recovery_email_param != "" &&
               recovery_email_param != old_recovery_email do
            RecoveryEmailVerification.set_recovery_email(updated_user.id, recovery_email_param)
            reloaded_user = Accounts.get_user!(socket.assigns.user.id)

            {reloaded_user,
             "Settings updated. Please check your recovery email for a verification link."}
          else
            {updated_user, "Settings updated successfully"}
          end

        mailboxes = Integrations.email_mailboxes(final_user.id)
        aliases = Integrations.email_aliases(final_user.id)

        {:noreply,
         socket
         |> assign(:user, final_user)
         |> assign(:changeset, Accounts.change_user(final_user))
         |> assign(:handle_changeset, Accounts.User.handle_changeset(final_user, %{}))
         |> assign(:mailboxes, mailboxes)
         |> assign(:aliases, aliases)
         |> notify_info(message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}

      _ ->
        updated_user = Accounts.get_user!(socket.assigns.user.id)
        mailboxes = Integrations.email_mailboxes(updated_user.id)
        aliases = Integrations.email_aliases(updated_user.id)

        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:changeset, Accounts.change_user(updated_user))
         |> assign(:handle_changeset, Accounts.User.handle_changeset(updated_user, %{}))
         |> assign(:mailboxes, mailboxes)
         |> assign(:aliases, aliases)
         |> notify_info("Settings updated")}
    end
  end

  defp bluesky_managed_error_message(:invalid_credentials) do
    "Current password is incorrect"
  end

  defp bluesky_managed_error_message(:already_enabled) do
    "Bluesky is already enabled"
  end

  defp bluesky_managed_error_message(:managed_pds_disabled) do
    "Managed Bluesky is disabled"
  end

  defp bluesky_managed_error_message(:user_not_found) do
    "User account could not be found"
  end

  defp bluesky_managed_error_message(:current_password_required) do
    "Current password is required"
  end

  defp bluesky_managed_error_message(:missing_managed_domain) do
    "Managed Bluesky domain is not configured"
  end

  defp bluesky_managed_error_message(:missing_managed_admin_password) do
    "Managed Bluesky admin password is not configured"
  end

  defp bluesky_managed_error_message(:invalid_managed_service_url) do
    "Managed Bluesky service URL is invalid"
  end

  defp bluesky_managed_error_message(:missing_identifier) do
    "Managed Bluesky identifier is missing. Disconnect and reconnect to repair this account."
  end

  defp bluesky_managed_error_message(:missing_invite_code) do
    "Managed Bluesky did not return an invite code"
  end

  defp bluesky_managed_error_message(:missing_did) do
    "Managed Bluesky did not return an account DID"
  end

  defp bluesky_managed_error_message(:missing_handle) do
    "Managed Bluesky did not return an account handle"
  end

  defp bluesky_managed_error_message(:missing_access_jwt) do
    "Managed Bluesky did not return a session token"
  end

  defp bluesky_managed_error_message(:missing_app_password) do
    "Managed Bluesky did not return an app password"
  end

  defp bluesky_managed_error_message(:invalid_json) do
    "Managed Bluesky returned an invalid response"
  end

  defp bluesky_managed_error_message({:create_invite_code_failed, 401}) do
    "Managed Bluesky admin credentials are invalid"
  end

  defp bluesky_managed_error_message({:create_invite_code_failed, _status}) do
    "Managed Bluesky could not issue an invite code"
  end

  defp bluesky_managed_error_message({:create_account_failed, 409}) do
    "A managed Bluesky account for this handle already exists. Try reconnecting instead."
  end

  defp bluesky_managed_error_message({:create_account_failed, _status}) do
    "Managed Bluesky could not create your account"
  end

  defp bluesky_managed_error_message({:create_session_failed, 401}) do
    "Could not authenticate with managed Bluesky. Stored Bluesky credentials may be stale."
  end

  defp bluesky_managed_error_message({:create_session_failed, _status}) do
    "Could not reconnect managed Bluesky account"
  end

  defp bluesky_managed_error_message({:create_app_password_failed, _status}) do
    "Managed Bluesky could not issue an app password"
  end

  defp bluesky_managed_error_message({:http_error, reason}) do
    "Managed Bluesky service is unreachable (#{format_bluesky_http_reason(reason)})"
  end

  defp bluesky_managed_error_message({:banned, _reason}) do
    "This account is banned and cannot connect to managed Bluesky"
  end

  defp bluesky_managed_error_message({:suspended, _until, _reason}) do
    "This account is suspended and cannot connect to managed Bluesky"
  end

  defp bluesky_managed_error_message(%Ecto.Changeset{}) do
    "Managed Bluesky connected, but local account settings could not be saved"
  end

  defp bluesky_managed_error_message(_) do
    "Could not update managed Bluesky connection"
  end

  defp format_bluesky_http_reason(reason) do
    reason |> inspect() |> String.replace_prefix(":", "")
  end

  defp bluesky_profile_url(user) do
    profile_id =
      [user.bluesky_did, user.bluesky_identifier]
      |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)
      |> case do
        value when is_binary(value) -> String.trim(value)
        _ -> nil
      end

    if profile_id do
      "https://bsky.app/profile/#{profile_id}"
    else
      nil
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.map_join("; ", & &1)
  end

  defp changeset_error_to_string(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} ->
      "#{Phoenix.Naming.humanize(field)} #{Enum.join(errors, ", ")}"
    end)
    |> Enum.map_join("; ", & &1)
  end

  defp default_token_form_params do
    %{
      "name" => "",
      "preset" => "search_read_only",
      "scopes" => [],
      "expires_in" => Integer.to_string(ApiToken.default_expiration_days())
    }
  end

  defp normalize_token_form_params(params) when is_map(params) do
    %{
      "name" => Map.get(params, "name", ""),
      "preset" => Map.get(params, "preset", "search_read_only"),
      "scopes" => normalize_scope_values(Map.get(params, "scopes", [])),
      "expires_in" =>
        case Map.get(params, "expires_in") do
          nil -> Integer.to_string(ApiToken.default_expiration_days())
          value -> to_string(value)
        end
    }
  end

  defp normalize_token_form_params(_params), do: default_token_form_params()

  defp resolve_token_scopes(%{"preset" => "custom", "scopes" => scopes}), do: scopes

  defp resolve_token_scopes(%{"preset" => preset}) when is_binary(preset) and preset != "" do
    scopes = ApiToken.preset_scopes(preset)
    if scopes == [], do: [], else: scopes
  end

  defp resolve_token_scopes(%{"scopes" => scopes}), do: scopes
  defp resolve_token_scopes(_), do: []

  defp token_form_params_for_existing_token(token) do
    preset = ApiToken.preset_for_scopes(token.scopes || [])

    %{
      "name" => "#{token.name} copy",
      "preset" => preset,
      "scopes" => if(preset == "custom", do: token.scopes || [], else: []),
      "expires_in" => Integer.to_string(ApiToken.default_expiration_days())
    }
  end

  defp token_presets do
    ApiToken.token_presets() ++
      [
        %{
          id: "custom",
          name: "Custom scopes",
          description: "Pick exact scopes for a least-privilege token.",
          scopes: []
        }
      ]
  end

  defp selected_token_preset(%{"preset" => preset}) when is_binary(preset) do
    Enum.find(token_presets(), &(&1.id == preset))
  end

  defp selected_token_preset(_), do: nil

  defp token_preview_scopes(%{"preset" => "custom", "scopes" => scopes}), do: scopes

  defp token_preview_scopes(%{"preset" => preset}) when is_binary(preset) do
    ApiToken.preset_scopes(preset)
  end

  defp token_preview_scopes(_), do: []

  defp humanize_avatar_upload_error(:too_large, limit_text),
    do: "File is too large (max #{limit_text})"

  defp humanize_avatar_upload_error(:not_accepted, _limit_text),
    do: "Unsupported file type. Use JPG, PNG, GIF, or WebP."

  defp humanize_avatar_upload_error(:too_many_files, _limit_text),
    do: "Only one avatar can be uploaded at a time."

  defp humanize_avatar_upload_error(error, _limit_text),
    do: "Upload error: #{inspect(error)}"

  defp normalize_scope_values(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_scope_values(scope) when is_binary(scope) do
    normalize_scope_values([scope])
  end

  defp normalize_scope_values(_), do: []

  defp maybe_clear_revealed_webhook_secret(socket, webhook_id) do
    case socket.assigns[:revealed_webhook_secret] do
      %{webhook_id: ^webhook_id} -> assign(socket, :revealed_webhook_secret, nil)
      _ -> socket
    end
  end

  defp normalize_selected_tab(tab) do
    if tab in valid_tabs() do
      tab
    else
      @default_tab
    end
  end

  defp setting_tabs do
    Enum.filter(@setting_tabs, fn {tab, _icon, _tone} -> tab_enabled?(tab) end)
  end

  defp valid_tabs do
    Enum.map(setting_tabs(), fn {tab, _icon, _tone} -> tab end)
  end

  defp tab_label("profile") do
    gettext("Profile")
  end

  defp tab_label("security") do
    gettext("Security")
  end

  defp tab_label("privacy") do
    gettext("Privacy")
  end

  defp tab_label("preferences") do
    gettext("Preferences")
  end

  defp tab_label("notifications") do
    gettext("Notifications")
  end

  defp tab_label("federation") do
    gettext("Federation")
  end

  defp tab_label("timeline") do
    gettext("Timeline")
  end

  defp tab_label("email") do
    gettext("Email")
  end

  defp tab_label("developer") do
    gettext("Developer")
  end

  defp tab_label("danger") do
    gettext("Danger Zone")
  end

  defp tab_label(_) do
    gettext("Settings")
  end

  defp tab_link_class(selected_tab, tab_id, tone) do
    base =
      "text-sm rounded-lg flex items-center gap-2 px-3 py-2 border transition-all duration-200"

    active? = selected_tab == tab_id

    case tone do
      :danger ->
        if active? do
          "#{base} border-error/40 bg-error/10 text-error font-medium"
        else
          "#{base} border-transparent text-error/80 hover:text-error hover:bg-error/10 hover:border-error/25"
        end

      _ ->
        if active? do
          "#{base} border-primary/35 bg-base-200/70 text-base-content font-medium"
        else
          "#{base} border-transparent text-base-content/80 hover:text-base-content hover:bg-base-200/60 hover:border-base-300"
        end
    end
  end

  defp checkbox_fields_for_tab("notifications") do
    [
      "notify_on_new_follower",
      "notify_on_direct_message",
      "notify_on_mention",
      "notify_on_reply",
      "notify_on_like",
      "notify_on_email_received",
      "notify_on_discussion_reply",
      "notify_on_comment"
    ]
  end

  defp checkbox_fields_for_tab("federation") do
    ["activitypub_manually_approve_followers"]
  end

  defp checkbox_fields_for_tab(_) do
    []
  end

  defp developer_modals(assigns) do
    ~H"""
    <!-- Create Token Modal -->
    <%= if @show_create_token_modal do %>
      <div class="modal modal-open">
        <div class="modal-box max-w-md">
          <h3 class="font-bold text-lg mb-4">{gettext("Create API Token")}</h3>

          <%= if @new_token do %>
            <!-- Token Created Successfully -->
            <div class="alert alert-warning mb-4">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>{gettext("Copy this token now. It will only be shown once!")}</span>
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text font-medium">{gettext("Your new token")}</span>
              </label>
              <div class="join w-full">
                <input
                  type="text"
                  value={@new_token}
                  readonly
                  class="input input-bordered join-item flex-1 font-mono text-sm"
                  id="new-token-input"
                />
                <button
                  type="button"
                  class="btn btn-primary join-item"
                  phx-hook="CopyToClipboard"
                  id="copy-token-btn"
                  data-copy-target="new-token-input"
                >
                  <.icon name="hero-clipboard-document" class="w-4 h-4" />
                </button>
              </div>
            </div>

            <div class="modal-action">
              <button phx-click="close_token_modal" class="btn btn-primary">{gettext("Done")}</button>
            </div>
          <% else %>
            <!-- Token Creation Form -->
            <.form
              for={@token_form}
              phx-submit="create_token"
              phx-change="token_form_changed"
              class="space-y-4"
            >
              <div class="form-control">
                <label class="label"><span class="label-text">{gettext("Token Name")}</span></label>
                <input
                  type="text"
                  name="token[name]"
                  value={@token_form[:name].value}
                  placeholder={gettext("e.g., My CLI Tool")}
                  class="input input-bordered w-full"
                  required
                  maxlength="100"
                />
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">{gettext("Integration Template")}</span>
                </label>
                <select
                  name="token[preset]"
                  class="select select-bordered w-full"
                >
                  <%= for preset <- token_presets() do %>
                    <option value={preset.id} selected={preset.id == @token_form_params["preset"]}>
                      {preset.name}
                    </option>
                  <% end %>
                </select>
                <%= if preset = selected_token_preset(@token_form_params) do %>
                  <label class="label">
                    <span class="label-text-alt text-base-content/60">{preset.description}</span>
                  </label>
                <% end %>
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">{gettext("Expiration")}</span></label>
                <select
                  name="token[expires_in]"
                  class="select select-bordered w-full"
                >
                  <option value="" selected={@token_form_params["expires_in"] == ""}>
                    {gettext("Never")}
                  </option>
                  <option value="30" selected={@token_form_params["expires_in"] == "30"}>
                    {gettext("30 days")}
                  </option>
                  <option value="90" selected={@token_form_params["expires_in"] == "90"}>
                    {gettext("90 days")}
                  </option>
                  <option value="365" selected={@token_form_params["expires_in"] == "365"}>
                    {gettext("1 year")}
                  </option>
                </select>
                <label class="label">
                  <span class="label-text-alt text-base-content/60">
                    {gettext("90 days is the recommended default for personal integrations.")}
                  </span>
                </label>
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">{gettext("Permission Preview")}</span>
                </label>
                <div class="rounded-lg border border-base-300 bg-base-200/50 p-3">
                  <div class="flex flex-wrap gap-1">
                    <%= for scope <- token_preview_scopes(@token_form_params) do %>
                      <span class="badge badge-sm badge-outline">{scope}</span>
                    <% end %>
                    <%= if token_preview_scopes(@token_form_params) == [] do %>
                      <span class="text-sm text-base-content/60">
                        {gettext("Choose a template or custom scopes.")}
                      </span>
                    <% end %>
                  </div>
                </div>
              </div>

              <%= if @token_form_params["preset"] == "custom" do %>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">{gettext("Custom Scopes")}</span>
                  </label>
                  <div class="max-h-52 overflow-y-auto border border-base-300 rounded-lg p-3 space-y-3">
                    <%= for {category, scopes} <- ApiToken.scopes_by_category() do %>
                      <div>
                        <div class="font-medium text-sm text-base-content/70 mb-2">{category}</div>
                        <div class="space-y-1">
                          <%= for {scope, description} <- scopes do %>
                            <label class="flex items-center gap-2 cursor-pointer">
                              <input
                                type="checkbox"
                                name="token[scopes][]"
                                value={scope}
                                checked={scope in (@token_form_params["scopes"] || [])}
                                class="checkbox checkbox-sm checkbox-primary"
                              />
                              <span class="text-sm font-mono">{scope}</span>
                              <span class="text-sm text-base-content/50 hidden sm:inline">
                                - {description}
                              </span>
                            </label>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <div class="modal-action">
                <button type="button" phx-click="close_token_modal" class="btn btn-ghost">
                  {gettext("Cancel")}
                </button>
                <button type="submit" class="btn btn-primary">
                  {gettext("Create Token")}
                </button>
              </div>
            </.form>
          <% end %>
        </div>
        <div class="modal-backdrop" phx-click="close_token_modal"></div>
      </div>
    <% end %>

    <!-- Create Webhook Modal -->
    <%= if @show_create_webhook_modal do %>
      <div class="modal modal-open">
        <div class="modal-box max-w-md">
          <h3 class="font-bold text-lg mb-4">{gettext("Add Webhook")}</h3>

          <.form for={@webhook_form} phx-submit="create_webhook" class="space-y-4">
            <div class="form-control">
              <label class="label"><span class="label-text">{gettext("Name")}</span></label>
              <input
                type="text"
                name="webhook[name]"
                value={@webhook_form[:name].value}
                placeholder={gettext("e.g., My Server")}
                class="input input-bordered w-full"
                required
                maxlength="100"
              />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">{gettext("URL")}</span></label>
              <input
                type="url"
                name="webhook[url]"
                value={@webhook_form[:url].value}
                placeholder="https://example.com/webhook"
                class="input input-bordered w-full font-mono text-sm"
                required
              />
              <label class="label">
                <span class="label-text-alt text-base-content/60">{gettext("Must be HTTPS")}</span>
              </label>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">{gettext("Events")}</span></label>
              <div class="grid grid-cols-2 gap-2">
                <%= for event <- Elektrine.Developer.Webhook.valid_events() do %>
                  <label class="flex items-center gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      name="webhook[events][]"
                      value={event}
                      class="checkbox checkbox-sm checkbox-primary"
                    />
                    <span class="text-sm font-mono">{event}</span>
                  </label>
                <% end %>
              </div>
            </div>

            <div class="modal-action">
              <button type="button" phx-click="close_webhook_modal" class="btn btn-ghost">
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary">
                {gettext("Add Webhook")}
              </button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close_webhook_modal"></div>
      </div>
    <% end %>
    """
  end

  def days_until_can_change_handle(user) do
    if user.handle_changed_at do
      thirty_days_from_change = DateTime.add(user.handle_changed_at, 30 * 24 * 60 * 60, :second)
      days_remaining = DateTime.diff(thirty_days_from_change, DateTime.utc_now(), :day)
      max(0, days_remaining)
    else
      0
    end
  end

  def format_fingerprint(fingerprint), do: Integrations.format_fingerprint(fingerprint)

  def wkd_hash(username), do: Integrations.wkd_hash(username)

  defp tab_enabled?("email"), do: Modules.enabled?(:email)
  defp tab_enabled?(_tab), do: true

  defp parse_token_expiration(nil), do: {:ok, nil}
  defp parse_token_expiration(""), do: {:ok, nil}

  defp parse_token_expiration(days) when is_binary(days) do
    case Integer.parse(days) do
      {days_int, ""} when days_int in [30, 90, 365] ->
        expires_at =
          DateTime.utc_now()
          |> DateTime.add(days_int * 24 * 60 * 60, :second)
          |> DateTime.truncate(:second)

        {:ok, expires_at}

      _ ->
        :error
    end
  end

  defp parse_token_expiration(_), do: :error

  defp refresh_user_invite_codes(socket) do
    assign(socket, :user_invite_codes, Accounts.list_user_invite_codes(socket.assigns.user.id))
  end

  defp invite_code_error_message(:invite_codes_disabled, _socket) do
    "Invite codes are only available while registration is invite-only."
  end

  defp invite_code_error_message(:insufficient_trust_level, socket) do
    min_trust_level = socket.assigns.invite_code_policy.min_trust_level
    "Invite creation unlocks at TL#{min_trust_level}."
  end

  defp invite_code_error_message(:invite_code_limit_reached, socket) do
    max_active_codes = socket.assigns.invite_code_policy.max_active_codes
    "You already have #{max_active_codes} active invite codes."
  end

  defp invite_code_error_message(:monthly_invite_code_limit_reached, socket) do
    max_codes_per_month = socket.assigns.invite_code_policy.max_codes_per_month
    "You already created #{max_codes_per_month} invite codes this month."
  end

  defp invite_code_error_message(:not_found, _socket), do: "Invite code not found"
  defp invite_code_error_message(_reason, _socket), do: "Could not update invite code"

  defp invite_code_status(invite_code) do
    cond do
      !invite_code.is_active -> :inactive
      Accounts.InviteCode.expired?(invite_code) -> :expired
      Accounts.InviteCode.exhausted?(invite_code) -> :exhausted
      true -> :active
    end
  end

  defp invite_code_status_label(invite_code) do
    case invite_code_status(invite_code) do
      :active -> "Active"
      :inactive -> "Inactive"
      :expired -> "Expired"
      :exhausted -> "Used"
    end
  end

  defp invite_code_status_badge_class(invite_code) do
    case invite_code_status(invite_code) do
      :active -> "badge-success"
      :inactive -> "badge-ghost"
      :expired -> "badge-warning"
      :exhausted -> "badge-error"
    end
  end

  defp invite_code_usage_percent(invite_code)
       when is_integer(invite_code.max_uses) and invite_code.max_uses > 0 do
    invite_code.uses_count
    |> Kernel./(invite_code.max_uses)
    |> Kernel.*(100)
    |> min(100.0)
    |> round()
  end

  defp invite_code_usage_percent(_invite_code), do: 0

  def email_tab_content(assigns) do
    case Integrations.user_settings_email_component() do
      nil ->
        ~H"""
        <div class="card glass-card shadow-lg">
          <div class="card-body p-4 sm:p-6">
            <h2 class="card-title text-lg sm:text-xl">Email</h2>
            <p class="text-sm text-base-content/70">
              Email settings are unavailable in this build.
            </p>
          </div>
        </div>
        """

      module ->
        module.email_tab(assigns)
    end
  end

  defp handle_email_settings_event(event, params, socket) do
    case Integrations.handle_user_settings_email_event(event, params, socket) do
      {:handled, updated_socket} -> updated_socket
    end
  end
end
