defmodule ElektrineWeb.UserSettingsLive do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts
  alias Elektrine.Accounts.RecoveryEmailVerification
  alias Elektrine.Bluesky.Managed, as: BlueskyManaged
  alias Elektrine.Developer
  alias Elektrine.Email
  alias Elektrine.Email.PGP
  alias Elektrine.Email.RateLimiter
  alias Elektrine.Email.Unsubscribes
  alias Elektrine.Email.ListTypes
  alias Elektrine.PasswordManager
  alias Elektrine.PasswordManager.VaultEntry
  alias Elektrine.RSS

  # NotificationCountHook and PresenceHook are provided by :main live_session in router
  # Only need to override auth to require_authenticated_user (live_session uses maybe_authenticated_user)
  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}

  @default_tab "profile"
  @setting_tabs [
    {"profile", "hero-user", :default},
    {"security", "hero-shield-check", :default},
    {"password-manager", "hero-lock-closed", :default},
    {"privacy", "hero-lock-closed", :default},
    {"preferences", "hero-cog-6-tooth", :default},
    {"notifications", "hero-bell", :default},
    {"federation", "hero-globe-alt", :default},
    {"timeline", "hero-queue-list", :default},
    {"email", "hero-envelope", :default},
    {"developer", "hero-code-bracket", :default},
    {"danger", "hero-exclamation-triangle", :danger}
  ]
  @valid_tabs Enum.map(@setting_tabs, fn {tab, _icon, _tone} -> tab end)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Admins get higher upload limits - 50MB vs 5MB
    avatar_limit = if user.is_admin, do: 50 * 1024 * 1024, else: 5 * 1024 * 1024

    # Only load essential data for initial render
    # Tab-specific data will be loaded lazily when tabs are selected
    {:ok,
     socket
     |> assign(:page_title, "Account Settings")
     |> assign(:user, user)
     |> assign(
       :bluesky_managed_enabled,
       Application.get_env(:elektrine, :bluesky, [])
       |> Keyword.get(:managed_enabled, false)
     )
     |> assign(:changeset, Accounts.change_user(user, %{}))
     |> assign(:handle_changeset, Accounts.User.handle_changeset(user, %{}))
     # Loading states for each tab
     |> assign(:loading_profile, true)
     |> assign(:loading_security, true)
     |> assign(:loading_email, true)
     |> assign(:loading_timeline, true)
     |> assign(:loading_password_manager, true)
     |> assign(:loading_developer, true)
     |> assign(:loading_danger, true)
     # Initialize with empty/default data (will be loaded when tab is selected)
     |> assign(:pending_deletion, nil)
     |> assign(:mailboxes, [])
     |> assign(:aliases, [])
     |> assign(:user_emails, [])
     |> assign(:lists, [])
     |> assign(:lists_by_type, %{})
     |> assign(:unsubscribe_status, %{})
     |> assign(:email_restriction_status, %{restricted: false})
     |> assign(:rss_subscriptions, [])
     |> assign(:new_feed_url, "")
     |> assign(:adding_feed, false)
     |> assign(:rss_error, nil)
     |> assign(:password_manager_entries, [])
     |> assign(:password_manager_revealed_entries, %{})
     |> assign(:password_manager_form, password_manager_entry_form(user.id))
     # Developer tab assigns
     |> assign(:api_tokens, [])
     |> assign(:webhooks, [])
     |> assign(:pending_exports, [])
     |> assign(:show_create_token_modal, false)
     |> assign(:show_create_webhook_modal, false)
     |> assign(
       :token_form,
       to_form(%{"name" => "", "scopes" => [], "expires_in" => ""}, as: :token)
     )
     |> assign(:webhook_form, to_form(%{"name" => "", "url" => "", "events" => []}, as: :webhook))
     |> assign(:new_token, nil)
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

    # Trigger lazy loading for the selected tab when connected
    if connected?(socket) do
      send(self(), {:load_tab_data, selected_tab})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    # Default to profile tab if no tab specified
    socket = assign(socket, :selected_tab, @default_tab)

    # Trigger lazy loading for the profile tab when connected
    if connected?(socket) do
      send(self(), {:load_tab_data, @default_tab})
    end

    {:noreply, socket}
  end

  # =============================================================================
  # Lazy Loading Tab Data
  # =============================================================================

  @impl true
  def handle_info({:load_tab_data, tab}, socket) do
    socket = load_tab_data(socket, tab)
    {:noreply, socket}
  end

  def handle_info(_message, socket) do
    # User settings runs under the shared :main live_session hooks, which can
    # deliver PubSub messages this view does not need to process.
    {:noreply, socket}
  end

  defp load_tab_data(socket, "profile") do
    if socket.assigns.loading_profile do
      user = socket.assigns.user

      # Load profile-related data in parallel
      pending_deletion_task = Task.async(fn -> Accounts.get_pending_deletion_request(user) end)
      mailboxes_task = Task.async(fn -> Email.get_user_mailboxes(user.id) end)
      aliases_task = Task.async(fn -> Email.list_aliases(user.id) end)

      pending_deletion = Task.await(pending_deletion_task)
      mailboxes = Task.await(mailboxes_task)
      aliases = Task.await(aliases_task)

      user_emails =
        (Enum.map(mailboxes, & &1.email) ++ Enum.map(aliases, & &1.alias_email))
        |> Enum.uniq()

      socket
      |> assign(:pending_deletion, pending_deletion)
      |> assign(:mailboxes, mailboxes)
      |> assign(:aliases, aliases)
      |> assign(:user_emails, user_emails)
      |> assign(:loading_profile, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "security") do
    if socket.assigns.loading_security do
      user = socket.assigns.user
      email_restriction_status = RateLimiter.get_restriction_status(user.id)

      socket
      |> assign(:email_restriction_status, email_restriction_status)
      |> assign(:loading_security, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "email") do
    if socket.assigns.loading_email do
      user = socket.assigns.user

      # Load email-related data in parallel
      lists_task = Task.async(fn -> ListTypes.subscribable_lists() end)
      lists_by_type_task = Task.async(fn -> ListTypes.lists_by_type() end)
      mailboxes_task = Task.async(fn -> Email.get_user_mailboxes(user.id) end)
      aliases_task = Task.async(fn -> Email.list_aliases(user.id) end)

      lists = Task.await(lists_task)
      lists_by_type = Task.await(lists_by_type_task)
      mailboxes = Task.await(mailboxes_task)
      aliases = Task.await(aliases_task)

      user_emails =
        (Enum.map(mailboxes, & &1.email) ++ Enum.map(aliases, & &1.alias_email))
        |> Enum.uniq()

      # Get unsubscribe status after we have list_ids
      list_ids = Enum.map(lists, & &1.id)
      unsubscribe_status = Unsubscribes.batch_check_unsubscribed(user_emails, list_ids)

      socket
      |> assign(:lists, lists)
      |> assign(:lists_by_type, lists_by_type)
      |> assign(:mailboxes, mailboxes)
      |> assign(:aliases, aliases)
      |> assign(:user_emails, user_emails)
      |> assign(:unsubscribe_status, unsubscribe_status)
      |> assign(:loading_email, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "timeline") do
    if socket.assigns.loading_timeline do
      user = socket.assigns.user
      rss_subscriptions = RSS.list_subscriptions(user.id)

      socket
      |> assign(:rss_subscriptions, rss_subscriptions)
      |> assign(:loading_timeline, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "password-manager") do
    if socket.assigns.loading_password_manager do
      user = socket.assigns.user

      socket
      |> assign(:password_manager_entries, PasswordManager.list_entries(user.id))
      |> assign(:loading_password_manager, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "developer") do
    if socket.assigns.loading_developer do
      user = socket.assigns.user

      # Load developer data in parallel
      api_tokens_task = Task.async(fn -> Developer.list_api_tokens(user.id) end)
      webhooks_task = Task.async(fn -> Developer.list_webhooks(user.id) end)
      pending_exports_task = Task.async(fn -> Developer.get_pending_exports(user.id) end)

      api_tokens = Task.await(api_tokens_task)
      webhooks = Task.await(webhooks_task)
      pending_exports = Task.await(pending_exports_task)

      socket
      |> assign(:api_tokens, api_tokens)
      |> assign(:webhooks, webhooks)
      |> assign(:pending_exports, pending_exports)
      |> assign(:loading_developer, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "danger") do
    if socket.assigns.loading_danger do
      user = socket.assigns.user
      pending_deletion = Accounts.get_pending_deletion_request(user)

      socket
      |> assign(:pending_deletion, pending_deletion)
      |> assign(:loading_danger, false)
    else
      socket
    end
  end

  # For tabs that don't need special loading (privacy, preferences, notifications, federation)
  defp load_tab_data(socket, _tab), do: socket

  # =============================================================================
  # Form Event Handlers
  # =============================================================================

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    tab = normalize_selected_tab(tab)

    # Update URL with tab parameter so it persists on refresh
    {:noreply, push_patch(socket, to: ~p"/account?tab=#{tab}")}
  end

  @impl true
  def handle_event("password_manager_validate", %{"entry" => params}, socket) do
    user = socket.assigns.current_user
    form = password_manager_entry_form(user.id, params, :validate)

    {:noreply, assign(socket, :password_manager_form, form)}
  end

  @impl true
  def handle_event("password_manager_create", %{"entry" => params}, socket) do
    user = socket.assigns.current_user

    case PasswordManager.create_entry(user.id, params) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(:password_manager_entries, PasswordManager.list_entries(user.id))
         |> assign(:password_manager_form, password_manager_entry_form(user.id))
         |> put_flash(:info, "Vault entry saved")}

      {:error, changeset} ->
        changeset = %{changeset | action: :insert}
        {:noreply, assign(socket, :password_manager_form, to_form(changeset, as: :entry))}
    end
  end

  @impl true
  def handle_event("password_manager_generate_password", _params, socket) do
    user = socket.assigns.current_user

    params =
      socket.assigns.password_manager_form
      |> password_manager_form_params()
      |> Map.put("password", generate_password())

    form = password_manager_entry_form(user.id, params, :validate)
    {:noreply, assign(socket, :password_manager_form, form)}
  end

  @impl true
  def handle_event("password_manager_reveal", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, entry} <- PasswordManager.get_entry(user.id, entry_id) do
      revealed = %{password: entry.password, notes: entry.notes}

      {:noreply,
       update(socket, :password_manager_revealed_entries, fn revealed_entries ->
         Map.put(revealed_entries, entry_id, revealed)
       end)}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid entry id")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Entry not found")}

      {:error, :decryption_failed} ->
        {:noreply, put_flash(socket, :error, "Could not decrypt this entry")}
    end
  end

  @impl true
  def handle_event("password_manager_hide", %{"id" => id}, socket) do
    with {:ok, entry_id} <- parse_entry_id(id) do
      {:noreply,
       update(socket, :password_manager_revealed_entries, fn revealed_entries ->
         Map.delete(revealed_entries, entry_id)
       end)}
    else
      :error -> {:noreply, put_flash(socket, :error, "Invalid entry id")}
    end
  end

  @impl true
  def handle_event("password_manager_delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, _entry} <- PasswordManager.delete_entry(user.id, entry_id) do
      {:noreply,
       socket
       |> assign(:password_manager_entries, PasswordManager.list_entries(user.id))
       |> update(:password_manager_revealed_entries, fn revealed_entries ->
         Map.delete(revealed_entries, entry_id)
       end)
       |> put_flash(:info, "Vault entry deleted")}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid entry id")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Entry not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete entry")}
    end
  end

  @impl true
  def handle_event("validate", %{"_target" => ["avatar"]}, socket) do
    # Skip validation for avatar uploads
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"_target" => ["user", _field]}, socket) do
    # Skip validation for individual checkbox changes - they'll be handled on save
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    # Only validate the fields that are actually in our form
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

    # Only coerce checkboxes for the active tab to avoid touching unrelated settings.
    checkbox_fields = checkbox_fields_for_tab(socket.assigns.selected_tab)

    params_with_checkboxes =
      Enum.reduce(checkbox_fields, filtered_params, fn field, acc ->
        case Map.get(acc, field) do
          "true" -> Map.put(acc, field, true)
          nil -> Map.put(acc, field, false)
          _ -> acc
        end
      end)

    # Handle empty timezone (auto-detect) by converting to nil
    final_params =
      case Map.get(params_with_checkboxes, "timezone") do
        "" -> Map.put(params_with_checkboxes, "timezone", nil)
        _ -> params_with_checkboxes
      end

    changeset =
      socket.assigns.user
      |> Accounts.change_user(final_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl true
  def handle_event("save", params, socket) when params == %{} do
    # Empty form submission (all checkboxes unchecked) - treat as all false
    handle_event("save", %{"user" => %{}}, socket)
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    # Check if uploads are still in progress
    {completed, in_progress} = uploaded_entries(socket, :avatar)

    if in_progress != [] do
      # Uploads still in progress - wait for them to complete
      {:noreply, put_flash(socket, :error, "Please wait for the upload to complete")}
    else
      # Handle avatar upload if present (only completed entries)
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

  def handle_event("toggle_subscription", %{"list_id" => list_id}, socket) do
    # Check if ANY email is currently subscribed to this list
    any_subscribed =
      Enum.any?(socket.assigns.user_emails, fn email ->
        !Unsubscribes.unsubscribed?(email, list_id)
      end)

    # If any are subscribed, unsubscribe all. Otherwise, subscribe all.
    action =
      if any_subscribed do
        # Unsubscribe all emails from this list
        Enum.each(socket.assigns.user_emails, fn email ->
          Unsubscribes.unsubscribe(email,
            list_id: list_id,
            user_id: socket.assigns.current_user.id
          )
        end)

        "Unsubscribed from"
      else
        # Resubscribe all emails to this list
        Enum.each(socket.assigns.user_emails, fn email ->
          Unsubscribes.resubscribe(email, list_id)
        end)

        "Resubscribed to"
      end

    # Rebuild status (single batch query)
    list_ids = Enum.map(socket.assigns.lists, & &1.id)

    unsubscribe_status =
      Unsubscribes.batch_check_unsubscribed(socket.assigns.user_emails, list_ids)

    list_name = ListTypes.get_name(list_id)

    {:noreply,
     socket
     |> assign(:unsubscribe_status, unsubscribe_status)
     |> notify_info("#{action} #{list_name} for all addresses")}
  end

  @impl true
  def handle_event("unsubscribe_all", %{"email" => email}, socket) do
    # Unsubscribe from all subscribable lists
    Enum.each(socket.assigns.lists, fn list ->
      Unsubscribes.unsubscribe(email, list_id: list.id, user_id: socket.assigns.current_user.id)
    end)

    # Rebuild status (single batch query)
    list_ids = Enum.map(socket.assigns.lists, & &1.id)

    unsubscribe_status =
      Unsubscribes.batch_check_unsubscribed(socket.assigns.user_emails, list_ids)

    {:noreply,
     socket
     |> assign(:unsubscribe_status, unsubscribe_status)
     |> notify_info("Unsubscribed from all mailing lists")}
  end

  @impl true
  def handle_event("resubscribe_all", %{"email" => email}, socket) do
    # Resubscribe to all lists
    Enum.each(socket.assigns.lists, fn list ->
      Unsubscribes.resubscribe(email, list.id)
    end)

    # Rebuild status (single batch query)
    list_ids = Enum.map(socket.assigns.lists, & &1.id)

    unsubscribe_status =
      Unsubscribes.batch_check_unsubscribed(socket.assigns.user_emails, list_ids)

    {:noreply,
     socket
     |> assign(:unsubscribe_status, unsubscribe_status)
     |> notify_info("Resubscribed to all mailing lists")}
  end

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
        {:noreply,
         socket
         |> notify_info("Your recovery email is already verified.")}

      {:error, :no_recovery_email} ->
        {:noreply,
         socket
         |> notify_error("Please add a recovery email address first.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> notify_error("Failed to send verification email. Please try again.")}
    end
  end

  @impl true
  def handle_event("upload_pgp_key", %{"pgp_public_key" => key_text}, socket) do
    user = socket.assigns.user

    case PGP.store_user_key(user, key_text) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:changeset, Accounts.change_user(updated_user, %{}))
         |> notify_info("PGP key uploaded successfully")}

      {:error, reason}
      when reason in [:not_pgp_key, :invalid_base64, :parse_error, :invalid_input] ->
        {:noreply,
         socket
         |> notify_error("Invalid PGP key format. Please paste a valid ASCII-armored public key.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> notify_error("Failed to upload PGP key. Please try again.")}
    end
  end

  @impl true
  def handle_event("delete_pgp_key", _params, socket) do
    user = socket.assigns.user

    case PGP.delete_user_key(user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:changeset, Accounts.change_user(updated_user, %{}))
         |> notify_info("PGP key removed")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> notify_error("Failed to remove PGP key")}
    end
  end

  # RSS Feed Management
  @impl true
  def handle_event("add_rss_feed", %{"url" => url}, socket) do
    url = String.trim(url)

    if url == "" do
      {:noreply, assign(socket, :rss_error, "Please enter a feed URL")}
    else
      socket = assign(socket, :adding_feed, true)

      case RSS.subscribe(socket.assigns.current_user.id, url) do
        {:ok, subscription} ->
          # Trigger immediate fetch of the new feed
          %{feed_id: subscription.feed_id}
          |> Elektrine.RSS.FetchFeedWorker.new()
          |> Oban.insert()

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
              {_, [constraint: :unique, constraint_name: _]} ->
                "You're already subscribed to this feed"

              _ ->
                "Failed to add feed. Please check the URL."
            end

          {:noreply,
           socket
           |> assign(:adding_feed, false)
           |> assign(:rss_error, error)}
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
        subscriptions =
          Enum.reject(socket.assigns.rss_subscriptions, &(&1.feed_id == feed_id))

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

    subscription =
      Enum.find(socket.assigns.rss_subscriptions, &(&1.id == subscription_id))

    if subscription do
      new_value = !subscription.show_in_timeline

      case RSS.update_subscription(subscription, %{show_in_timeline: new_value}) do
        {:ok, updated} ->
          subscriptions =
            Enum.map(socket.assigns.rss_subscriptions, fn s ->
              if s.id == subscription_id, do: updated, else: s
            end)

          {:noreply, assign(socket, :rss_subscriptions, subscriptions)}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to update subscription")}
      end
    else
      {:noreply, socket}
    end
  end

  # =============================================================================
  # Developer Tab Event Handlers
  # =============================================================================

  @impl true
  def handle_event("show_create_token_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_token_modal, true)
     |> assign(:new_token, nil)
     |> assign(
       :token_form,
       to_form(%{"name" => "", "scopes" => [], "expires_in" => ""}, as: :token)
     )}
  end

  @impl true
  def handle_event("close_token_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_token_modal, false)
     |> assign(:new_token, nil)}
  end

  @impl true
  def handle_event("create_token", %{"token" => token_params}, socket) do
    user = socket.assigns.current_user
    scopes = Map.get(token_params, "scopes", [])

    # Parse expiration
    expires_at =
      case token_params["expires_in"] do
        "" ->
          nil

        nil ->
          nil

        days ->
          days_int = String.to_integer(days)

          DateTime.utc_now()
          |> DateTime.add(days_int * 24 * 60 * 60, :second)
          |> DateTime.truncate(:second)
      end

    attrs = %{
      name: token_params["name"],
      scopes: scopes,
      expires_at: expires_at
    }

    case Developer.create_api_token(user.id, attrs) do
      {:ok, token} ->
        {:noreply,
         socket
         |> assign(:new_token, token.token)
         |> assign(:api_tokens, Developer.list_api_tokens(user.id))}

      {:error, changeset} ->
        error_msg = changeset_error_to_string(changeset)
        {:noreply, notify_error(socket, "Failed to create token: #{error_msg}")}
    end
  end

  @impl true
  def handle_event("revoke_token", %{"id" => token_id}, socket) do
    user = socket.assigns.current_user

    case Developer.revoke_api_token(user.id, String.to_integer(token_id)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:api_tokens, Developer.list_api_tokens(user.id))
         |> notify_success("Token revoked successfully")}

      {:error, :not_found} ->
        {:noreply, notify_error(socket, "Token not found")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to revoke token")}
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

    attrs = %{
      name: webhook_params["name"],
      url: webhook_params["url"],
      events: events
    }

    case Developer.create_webhook(user.id, attrs) do
      {:ok, _webhook} ->
        {:noreply,
         socket
         |> assign(:webhooks, Developer.list_webhooks(user.id))
         |> assign(:show_create_webhook_modal, false)
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
             |> assign(:webhooks, Developer.list_webhooks(user.id))
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
             |> assign(:webhooks, Developer.list_webhooks(user.id))
             |> notify_success("Webhook test delivered (HTTP #{status})")}

          {:error, :not_found} ->
            {:noreply, notify_error(socket, "Webhook not found")}

          {:error, {:http_error, status}} ->
            {:noreply,
             socket
             |> assign(:webhooks, Developer.list_webhooks(user.id))
             |> notify_error("Webhook endpoint returned HTTP #{status}")}

          {:error, {:request_failed, reason}} ->
            {:noreply,
             socket
             |> assign(:webhooks, Developer.list_webhooks(user.id))
             |> notify_error("Webhook test failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, notify_error(socket, "Invalid webhook id")}
    end
  end

  @impl true
  def handle_event("export_data", %{"type" => export_type}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      export_type: export_type,
      format: "json"
    }

    case Developer.create_export(user.id, attrs) do
      {:ok, export} ->
        # Enqueue background job to process export
        %{export_id: export.id}
        |> Elektrine.Developer.ExportWorker.new()
        |> Oban.insert()

        {:noreply,
         socket
         |> assign(:pending_exports, Developer.get_pending_exports(user.id))
         |> notify_success("Export started. You'll be notified when it's ready.")}

      {:error, changeset} ->
        error_msg = changeset_error_to_string(changeset)
        {:noreply, notify_error(socket, "Failed to start export: #{error_msg}")}
    end
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp save_user_settings(socket, user_params_with_avatar) do
    # Separate handle update from other updates
    {handle_param, other_params} = Map.pop(user_params_with_avatar, "handle")

    # Bluesky linkage fields are provisioned by the managed flow only.
    other_params_sanitized =
      Map.drop(other_params, [
        "bluesky_enabled",
        "bluesky_identifier",
        "bluesky_app_password",
        "bluesky_pds_url"
      ])

    # Update handle if changed
    handle_result =
      if handle_param && handle_param != socket.assigns.user.handle do
        Accounts.update_user_handle(socket.assigns.user, handle_param)
      else
        {:ok, socket.assigns.user}
      end

    # Only coerce checkboxes for the active tab to avoid touching unrelated settings.
    checkbox_fields = checkbox_fields_for_tab(socket.assigns.selected_tab)

    other_params_with_checkboxes =
      Enum.reduce(checkbox_fields, other_params_sanitized, fn field, acc ->
        case Map.get(acc, field) do
          "true" -> Map.put(acc, field, true)
          nil -> Map.put(acc, field, false)
          _ -> acc
        end
      end)

    # Handle empty timezone (auto-detect) by converting to nil
    params_with_timezone =
      case Map.get(other_params_with_checkboxes, "timezone") do
        "" -> Map.put(other_params_with_checkboxes, "timezone", nil)
        _ -> other_params_with_checkboxes
      end

    # Keep existing app password when settings form leaves this field blank.
    params_with_bluesky_password =
      case Map.get(params_with_timezone, "bluesky_app_password") do
        "" -> Map.delete(params_with_timezone, "bluesky_app_password")
        _ -> params_with_timezone
      end

    # Extract recovery_email to handle separately (needs special verification logic)
    {recovery_email_param, final_params} = Map.pop(params_with_bluesky_password, "recovery_email")

    # Update other fields (excluding recovery_email)
    other_result =
      if map_size(final_params) > 0 do
        Accounts.update_user(socket.assigns.user, final_params)
      else
        {:ok, socket.assigns.user}
      end

    case {handle_result, other_result} do
      {{:ok, _user1}, {:ok, _user2}} ->
        # Reload user to get all updates
        updated_user = Accounts.get_user!(socket.assigns.user.id)

        # Check if recovery email changed and needs verification
        old_recovery_email = socket.assigns.user.recovery_email

        {final_user, message} =
          if recovery_email_param && recovery_email_param != "" &&
               recovery_email_param != old_recovery_email do
            # Recovery email changed, mark as unverified and send verification
            RecoveryEmailVerification.set_recovery_email(updated_user.id, recovery_email_param)
            # Reload user again after setting recovery email
            reloaded_user = Accounts.get_user!(socket.assigns.user.id)

            {reloaded_user,
             "Settings updated. Please check your recovery email for a verification link."}
          else
            {updated_user, "Settings updated successfully"}
          end

        # Refresh email data
        mailboxes = Email.get_user_mailboxes(final_user.id)
        aliases = Email.list_aliases(final_user.id)

        {:noreply,
         socket
         |> assign(:user, final_user)
         |> assign(:changeset, Accounts.change_user(final_user))
         |> assign(:handle_changeset, Accounts.User.handle_changeset(final_user, %{}))
         |> assign(:mailboxes, mailboxes)
         |> assign(:aliases, aliases)
         |> notify_info(message)}

      {{:error, {:error, %Ecto.Changeset{} = changeset}}, _} ->
        {:noreply,
         socket
         |> assign(:handle_changeset, changeset)
         |> notify_error("Could not update handle: #{format_changeset_errors(changeset)}")}

      {_, {:error, %Ecto.Changeset{} = changeset}} ->
        {:noreply, assign(socket, :changeset, changeset)}

      _ ->
        # Reload user just in case
        updated_user = Accounts.get_user!(socket.assigns.user.id)
        # Refresh email data
        mailboxes = Email.get_user_mailboxes(updated_user.id)
        aliases = Email.list_aliases(updated_user.id)

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

  defp bluesky_managed_error_message(:invalid_credentials), do: "Current password is incorrect"
  defp bluesky_managed_error_message(:already_enabled), do: "Bluesky is already enabled"
  defp bluesky_managed_error_message(:managed_pds_disabled), do: "Managed Bluesky is disabled"
  defp bluesky_managed_error_message(:user_not_found), do: "User account could not be found"

  defp bluesky_managed_error_message(:current_password_required),
    do: "Current password is required"

  defp bluesky_managed_error_message(:missing_managed_domain),
    do: "Managed Bluesky domain is not configured"

  defp bluesky_managed_error_message(:missing_managed_admin_password),
    do: "Managed Bluesky admin password is not configured"

  defp bluesky_managed_error_message(:invalid_managed_service_url),
    do: "Managed Bluesky service URL is invalid"

  defp bluesky_managed_error_message(:missing_identifier),
    do: "Managed Bluesky identifier is missing. Disconnect and reconnect to repair this account."

  defp bluesky_managed_error_message(:missing_invite_code),
    do: "Managed Bluesky did not return an invite code"

  defp bluesky_managed_error_message(:missing_did),
    do: "Managed Bluesky did not return an account DID"

  defp bluesky_managed_error_message(:missing_handle),
    do: "Managed Bluesky did not return an account handle"

  defp bluesky_managed_error_message(:missing_access_jwt),
    do: "Managed Bluesky did not return a session token"

  defp bluesky_managed_error_message(:missing_app_password),
    do: "Managed Bluesky did not return an app password"

  defp bluesky_managed_error_message(:invalid_json),
    do: "Managed Bluesky returned an invalid response"

  defp bluesky_managed_error_message({:create_invite_code_failed, 401}),
    do: "Managed Bluesky admin credentials are invalid"

  defp bluesky_managed_error_message({:create_invite_code_failed, _status}),
    do: "Managed Bluesky could not issue an invite code"

  defp bluesky_managed_error_message({:create_account_failed, 409}),
    do: "A managed Bluesky account for this handle already exists. Try reconnecting instead."

  defp bluesky_managed_error_message({:create_account_failed, _status}),
    do: "Managed Bluesky could not create your account"

  defp bluesky_managed_error_message({:create_session_failed, 401}),
    do:
      "Could not authenticate with managed Bluesky. Ensure your account password matches your managed Bluesky password."

  defp bluesky_managed_error_message({:create_session_failed, _status}),
    do: "Could not reconnect managed Bluesky account"

  defp bluesky_managed_error_message({:create_app_password_failed, _status}),
    do: "Managed Bluesky could not issue an app password"

  defp bluesky_managed_error_message({:http_error, reason}),
    do: "Managed Bluesky service is unreachable (#{format_bluesky_http_reason(reason)})"

  defp bluesky_managed_error_message({:banned, _reason}),
    do: "This account is banned and cannot connect to managed Bluesky"

  defp bluesky_managed_error_message({:suspended, _until, _reason}),
    do: "This account is suspended and cannot connect to managed Bluesky"

  defp bluesky_managed_error_message(%Ecto.Changeset{}),
    do: "Managed Bluesky connected, but local account settings could not be saved"

  defp bluesky_managed_error_message(_), do: "Could not update managed Bluesky connection"

  defp format_bluesky_http_reason(reason) do
    reason
    |> inspect()
    |> String.replace_prefix(":", "")
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

  # Helper to format changeset errors
  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
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

  defp normalize_selected_tab(tab) when tab in @valid_tabs, do: tab
  defp normalize_selected_tab(_tab), do: @default_tab

  defp setting_tabs, do: @setting_tabs

  defp tab_label("profile"), do: gettext("Profile")
  defp tab_label("security"), do: gettext("Security")
  defp tab_label("password-manager"), do: gettext("Password Manager")
  defp tab_label("privacy"), do: gettext("Privacy")
  defp tab_label("preferences"), do: gettext("Preferences")
  defp tab_label("notifications"), do: gettext("Notifications")
  defp tab_label("federation"), do: gettext("Federation")
  defp tab_label("timeline"), do: gettext("Timeline")
  defp tab_label("email"), do: gettext("Email")
  defp tab_label("developer"), do: gettext("Developer")
  defp tab_label("danger"), do: gettext("Danger Zone")
  defp tab_label(_), do: gettext("Settings")

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

  defp checkbox_fields_for_tab(_), do: []

  # Calculate days until handle can be changed
  def days_until_can_change_handle(user) do
    if user.handle_changed_at do
      thirty_days_from_change = DateTime.add(user.handle_changed_at, 30 * 24 * 60 * 60, :second)
      days_remaining = DateTime.diff(thirty_days_from_change, DateTime.utc_now(), :day)
      max(0, days_remaining)
    else
      0
    end
  end

  # Helper functions for template
  defp type_badge_class(:transactional), do: "badge-error"
  defp type_badge_class(:marketing), do: "badge-primary"
  defp type_badge_class(:notifications), do: "badge-info"

  defp format_type(:transactional), do: "Transactional"
  defp format_type(:marketing), do: "Marketing"
  defp format_type(:notifications), do: "Notifications"

  # Format PGP fingerprint with spaces for readability (groups of 4)
  def format_fingerprint(nil), do: ""

  def format_fingerprint(fingerprint) do
    fingerprint
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  # Compute WKD hash for username
  def wkd_hash(username) do
    PGP.wkd_hash(String.downcase(username))
  end

  defp password_manager_entry_form(user_id, attrs \\ %{}, action \\ nil) do
    changeset =
      %VaultEntry{}
      |> VaultEntry.form_changeset(Map.put(attrs, "user_id", user_id))
      |> Map.put(:action, action)

    to_form(changeset, as: :entry)
  end

  defp parse_entry_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {entry_id, ""} -> {:ok, entry_id}
      _ -> :error
    end
  end

  defp parse_entry_id(_id), do: :error

  defp password_manager_form_params(%Phoenix.HTML.Form{
         source: %Ecto.Changeset{params: params}
       })
       when is_map(params) do
    Map.drop(params, ["user_id"])
  end

  defp password_manager_form_params(_form), do: %{}

  defp generate_password(length \\ 24) do
    lowercase = Enum.to_list(?a..?z)
    uppercase = Enum.to_list(?A..?Z)
    digits = Enum.to_list(?0..?9)
    symbols = ~c"!@#$%^&*()-_=+"

    required = [
      random_char(lowercase),
      random_char(uppercase),
      random_char(digits),
      random_char(symbols)
    ]

    all_chars = lowercase ++ uppercase ++ digits ++ symbols
    random_chars = for _ <- 1..max(length - length(required), 0), do: random_char(all_chars)

    (required ++ random_chars)
    |> Enum.shuffle()
    |> List.to_string()
  end

  defp random_char(charlist), do: Enum.at(charlist, :rand.uniform(length(charlist)) - 1)
end
