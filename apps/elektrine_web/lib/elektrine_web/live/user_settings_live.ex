defmodule ElektrineWeb.UserSettingsLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Accounts
  alias Elektrine.Accounts.RecoveryEmailVerification
  alias Elektrine.Bluesky.Managed, as: BlueskyManaged
  alias Elektrine.Developer
  alias Elektrine.Email
  alias Elektrine.Email.ListTypes
  alias Elektrine.Email.PGP
  alias Elektrine.Email.RateLimiter
  alias Elektrine.Email.Unsubscribes
  alias Elektrine.PasswordManager
  alias Elektrine.PasswordManager.VaultEntry
  alias Elektrine.RSS
  on_mount({ElektrineWeb.Live.AuthHooks, :require_authenticated_user})
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

    avatar_limit =
      if user.is_admin do
        50 * 1024 * 1024
      else
        5 * 1024 * 1024
      end

    {:ok,
     socket
     |> assign(:page_title, "Account Settings")
     |> assign(:user, user)
     |> assign(
       :bluesky_managed_enabled,
       Application.get_env(:elektrine, :bluesky, []) |> Keyword.get(:managed_enabled, false)
     )
     |> assign(:changeset, Accounts.change_user(user, %{}))
     |> assign(:handle_changeset, Accounts.User.handle_changeset(user, %{}))
     |> assign(:loading_profile, true)
     |> assign(:loading_security, true)
     |> assign(:loading_email, true)
     |> assign(:loading_timeline, true)
     |> assign(:loading_password_manager, true)
     |> assign(:loading_developer, true)
     |> assign(:loading_danger, true)
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
     |> assign(:password_manager_vault_configured, false)
     |> assign(:password_manager_vault_verifier, nil)
     |> assign(:password_manager_form, password_manager_entry_form(user.id))
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
      pending_deletion_task = Task.async(fn -> Accounts.get_pending_deletion_request(user) end)
      mailboxes_task = Task.async(fn -> Email.get_user_mailboxes(user.id) end)
      aliases_task = Task.async(fn -> Email.list_aliases(user.id) end)
      pending_deletion = Task.await(pending_deletion_task)
      mailboxes = Task.await(mailboxes_task)
      aliases = Task.await(aliases_task)

      user_emails =
        (Enum.map(mailboxes, & &1.email) ++ Enum.map(aliases, & &1.alias_email)) |> Enum.uniq()

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
      lists_task = Task.async(fn -> ListTypes.subscribable_lists() end)
      lists_by_type_task = Task.async(fn -> ListTypes.lists_by_type() end)
      mailboxes_task = Task.async(fn -> Email.get_user_mailboxes(user.id) end)
      aliases_task = Task.async(fn -> Email.list_aliases(user.id) end)
      lists = Task.await(lists_task)
      lists_by_type = Task.await(lists_by_type_task)
      mailboxes = Task.await(mailboxes_task)
      aliases = Task.await(aliases_task)

      user_emails =
        (Enum.map(mailboxes, & &1.email) ++ Enum.map(aliases, & &1.alias_email)) |> Enum.uniq()

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
      socket |> assign(:rss_subscriptions, rss_subscriptions) |> assign(:loading_timeline, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "password-manager") do
    if socket.assigns.loading_password_manager do
      user = socket.assigns.user
      vault_settings = PasswordManager.get_vault_settings(user.id)
      vault_configured = not is_nil(vault_settings)

      entries =
        if vault_configured,
          do: PasswordManager.list_entries(user.id, include_secrets: true),
          else: []

      socket
      |> assign(:password_manager_vault_configured, vault_configured)
      |> assign(
        :password_manager_vault_verifier,
        vault_settings && vault_settings.encrypted_verifier
      )
      |> assign(:password_manager_entries, entries)
      |> assign(:loading_password_manager, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, "developer") do
    if socket.assigns.loading_developer do
      user = socket.assigns.user
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
      socket |> assign(:pending_deletion, pending_deletion) |> assign(:loading_danger, false)
    else
      socket
    end
  end

  defp load_tab_data(socket, _tab) do
    socket
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    tab = normalize_selected_tab(tab)
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

    with {:ok, params} <- decode_encrypted_params(params),
         {:ok, _entry} <- PasswordManager.create_entry(user.id, params) do
      {:noreply,
       socket
       |> assign(
         :password_manager_entries,
         PasswordManager.list_entries(user.id, include_secrets: true)
       )
       |> assign(:password_manager_form, password_manager_entry_form(user.id))
       |> put_flash(:info, "Vault entry saved")}
    else
      {:error, :invalid_payload} ->
        {:noreply,
         socket |> put_flash(:error, "Vault payload is invalid. Unlock your vault and try again.")}

      {:error, :vault_not_configured} ->
        {:noreply,
         socket |> put_flash(:error, "Set up your vault passphrase before saving entries.")}

      {:error, changeset} ->
        changeset = %{changeset | action: :insert}
        {:noreply, assign(socket, :password_manager_form, to_form(changeset, as: :entry))}
    end
  end

  @impl true
  def handle_event("password_manager_setup_vault", %{"vault" => params}, socket) do
    user = socket.assigns.current_user

    with {:ok, params} <- decode_setup_params(params),
         {:ok, settings} <- PasswordManager.setup_vault(user.id, params) do
      {:noreply,
       socket
       |> assign(:password_manager_vault_configured, true)
       |> assign(:password_manager_vault_verifier, settings.encrypted_verifier)
       |> assign(
         :password_manager_entries,
         PasswordManager.list_entries(user.id, include_secrets: true)
       )
       |> put_flash(:info, "Vault configured")}
    else
      {:error, :invalid_payload} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Vault setup payload is invalid. Use the setup form to continue."
         )}

      {:error, changeset} ->
        details =
          changeset.errors
          |> Keyword.keys()
          |> Enum.map_join(", ", &to_string/1)

        message =
          if details == "" do
            "Could not configure vault."
          else
            "Could not configure vault (#{details})."
          end

        {:noreply, socket |> put_flash(:error, message)}
    end
  end

  @impl true
  def handle_event("password_manager_delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, _entry} <- PasswordManager.delete_entry(user.id, entry_id) do
      {:noreply,
       socket
       |> assign(
         :password_manager_entries,
         PasswordManager.list_entries(user.id, include_secrets: true)
       )
       |> put_flash(:info, "Vault entry deleted")}
    else
      :error -> {:noreply, put_flash(socket, :error, "Invalid entry id")}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "Entry not found")}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not delete entry")}
    end
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

  def handle_event("toggle_subscription", %{"list_id" => list_id}, socket) do
    any_subscribed =
      Enum.any?(socket.assigns.user_emails, fn email ->
        !Unsubscribes.unsubscribed?(email, list_id)
      end)

    action =
      if any_subscribed do
        Enum.each(socket.assigns.user_emails, fn email ->
          Unsubscribes.unsubscribe(email,
            list_id: list_id,
            user_id: socket.assigns.current_user.id
          )
        end)

        "Unsubscribed from"
      else
        Enum.each(socket.assigns.user_emails, fn email ->
          Unsubscribes.resubscribe(email, list_id)
        end)

        "Resubscribed to"
      end

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
    Enum.each(socket.assigns.lists, fn list ->
      Unsubscribes.unsubscribe(email, list_id: list.id, user_id: socket.assigns.current_user.id)
    end)

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
    Enum.each(socket.assigns.lists, fn list -> Unsubscribes.resubscribe(email, list.id) end)
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
        {:noreply, socket |> notify_info("Your recovery email is already verified.")}

      {:error, :no_recovery_email} ->
        {:noreply, socket |> notify_error("Please add a recovery email address first.")}

      {:error, _reason} ->
        {:noreply, socket |> notify_error("Failed to send verification email. Please try again.")}
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
        {:noreply, socket |> notify_error("Failed to upload PGP key. Please try again.")}
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
        {:noreply, socket |> notify_error("Failed to remove PGP key")}
    end
  end

  @impl true
  def handle_event("add_rss_feed", %{"url" => url}, socket) do
    url = String.trim(url)

    if url == "" do
      {:noreply, assign(socket, :rss_error, "Please enter a feed URL")}
    else
      socket = assign(socket, :adding_feed, true)

      case RSS.subscribe(socket.assigns.current_user.id, url) do
        {:ok, subscription} ->
          %{feed_id: subscription.feed_id} |> Elektrine.RSS.FetchFeedWorker.new() |> Oban.insert()

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
    {:noreply, socket |> assign(:show_create_token_modal, false) |> assign(:new_token, nil)}
  end

  @impl true
  def handle_event("create_token", %{"token" => token_params}, socket) do
    user = socket.assigns.current_user
    scopes = Map.get(token_params, "scopes", [])

    case parse_token_expiration(token_params["expires_in"]) do
      {:ok, expires_at} ->
        attrs = %{name: token_params["name"], scopes: scopes, expires_at: expires_at}

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

      :error ->
        {:noreply, notify_error(socket, "Invalid token expiration. Use 30, 90, or 365 days.")}
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
             |> assign(:api_tokens, Developer.list_api_tokens(user.id))
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
    attrs = %{export_type: export_type, format: "json"}

    case Developer.create_export(user.id, attrs) do
      {:ok, export} ->
        %{export_id: export.id} |> Elektrine.Developer.ExportWorker.new() |> Oban.insert()

        {:noreply,
         socket
         |> assign(:pending_exports, Developer.get_pending_exports(user.id))
         |> notify_success("Export started. You'll be notified when it's ready.")}

      {:error, changeset} ->
        error_msg = changeset_error_to_string(changeset)
        {:noreply, notify_error(socket, "Failed to start export: #{error_msg}")}
    end
  end

  defp save_user_settings(socket, user_params_with_avatar) do
    {handle_param, other_params} = Map.pop(user_params_with_avatar, "handle")

    other_params_sanitized =
      Map.drop(other_params, [
        "bluesky_enabled",
        "bluesky_identifier",
        "bluesky_app_password",
        "bluesky_pds_url"
      ])

    handle_result =
      if handle_param && handle_param != socket.assigns.user.handle do
        Accounts.update_user_handle(socket.assigns.user, handle_param)
      else
        {:ok, socket.assigns.user}
      end

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

    case {handle_result, other_result} do
      {{:ok, _user1}, {:ok, _user2}} ->
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
        updated_user = Accounts.get_user!(socket.assigns.user.id)
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
    "Could not authenticate with managed Bluesky. Ensure your account password matches your managed Bluesky password."
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

  defp normalize_selected_tab(tab) when tab in @valid_tabs do
    tab
  end

  defp normalize_selected_tab(_tab) do
    @default_tab
  end

  defp setting_tabs do
    @setting_tabs
  end

  defp tab_label("profile") do
    gettext("Profile")
  end

  defp tab_label("security") do
    gettext("Security")
  end

  defp tab_label("password-manager") do
    gettext("Password Manager")
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
            <.form for={@token_form} phx-submit="create_token" class="space-y-4">
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
                <label class="label"><span class="label-text">{gettext("Expiration")}</span></label>
                <select name="token[expires_in]" class="select select-bordered w-full">
                  <option value="">{gettext("Never")}</option>
                  <option value="30">{gettext("30 days")}</option>
                  <option value="90">{gettext("90 days")}</option>
                  <option value="365">{gettext("1 year")}</option>
                </select>
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">{gettext("Scopes")}</span></label>
                <div class="max-h-52 overflow-y-auto border border-base-300 rounded-lg p-3 space-y-3">
                  <%= for {category, scopes} <- Elektrine.Developer.ApiToken.scopes_by_category() do %>
                    <div>
                      <div class="font-medium text-sm text-base-content/70 mb-2">{category}</div>
                      <div class="space-y-1">
                        <%= for {scope, description} <- scopes do %>
                          <label class="flex items-center gap-2 cursor-pointer">
                            <input
                              type="checkbox"
                              name="token[scopes][]"
                              value={scope}
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

  defp type_badge_class(:transactional) do
    "badge-error"
  end

  defp type_badge_class(:marketing) do
    "badge-primary"
  end

  defp type_badge_class(:notifications) do
    "badge-info"
  end

  defp format_type(:transactional) do
    "Transactional"
  end

  defp format_type(:marketing) do
    "Marketing"
  end

  defp format_type(:notifications) do
    "Notifications"
  end

  def format_fingerprint(nil) do
    ""
  end

  def format_fingerprint(fingerprint) do
    fingerprint
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

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

  defp parse_entry_id(_id) do
    :error
  end

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

  defp decode_setup_params(params) when is_map(params) do
    decode_payload_field(params, "encrypted_verifier", required: true)
  end

  defp decode_setup_params(_params), do: {:error, :invalid_payload}

  defp decode_encrypted_params(params) when is_map(params) do
    case decode_payload_field(params, "encrypted_password", required: true) do
      {:ok, decoded_params} ->
        decode_payload_field(decoded_params, "encrypted_notes", required: false)

      error ->
        error
    end
  end

  defp decode_encrypted_params(_params), do: {:error, :invalid_payload}

  defp decode_payload_field(params, field, opts) do
    required? = Keyword.get(opts, :required, false)

    case Map.get(params, field) do
      nil ->
        if required?, do: {:error, :invalid_payload}, else: {:ok, params}

      "" ->
        if required?, do: {:error, :invalid_payload}, else: {:ok, Map.put(params, field, nil)}

      value when is_map(value) ->
        {:ok, params}

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> {:ok, Map.put(params, field, decoded)}
          _ -> {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp encode_payload(nil), do: ""
  defp encode_payload(payload) when is_map(payload), do: Jason.encode!(payload)
end
