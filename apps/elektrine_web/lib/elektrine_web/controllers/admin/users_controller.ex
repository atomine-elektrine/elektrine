defmodule ElektrineWeb.Admin.UsersController do
  @moduledoc """
  Controller for admin user management functions including creation, editing,
  banning, suspending, impersonation, and deletion of users.
  """

  use ElektrineWeb, :controller

  alias Elektrine.{Accounts, Email, Repo}
  import Ecto.Query

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}
  plug :assign_timezone_and_format

  defp assign_timezone_and_format(conn, _opts) do
    current_user = conn.assigns[:current_user]

    timezone =
      if current_user && current_user.timezone, do: current_user.timezone, else: "Etc/UTC"

    time_format =
      if current_user && current_user.time_format, do: current_user.time_format, else: "12"

    conn
    |> assign(:timezone, timezone)
    |> assign(:time_format, time_format)
  end

  def index(conn, params) do
    search_query = Map.get(params, "search", "")
    page = SafeConvert.parse_page(params)
    per_page = 50

    # Check for exact match syntax (wrapped in quotes)
    is_exact_match =
      String.starts_with?(search_query, "\"") && String.ends_with?(search_query, "\"")

    clean_query =
      if is_exact_match do
        String.trim(search_query, "\"")
      else
        search_query
      end

    {users, total_count} =
      cond do
        clean_query == "" ->
          get_all_users_paginated(page, per_page)

        is_exact_match ->
          search_users_exact(clean_query, page, per_page)

        true ->
          search_users_paginated(clean_query, page, per_page)
      end

    # Add aliases to each user
    users_with_aliases =
      users
      |> Enum.map(fn user ->
        aliases = Email.list_aliases(user.id)
        Map.put(user, :aliases, aliases)
      end)

    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)

    # Get IP statistics
    ip_stats = %{
      unique_registration_ips: get_unique_registration_ip_count(),
      unique_login_ips: get_unique_login_ip_count(),
      total_users: total_count
    }

    render(conn, :users,
      users: users_with_aliases,
      search_query: search_query,
      ip_stats: ip_stats,
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range
    )
  end

  def multi_accounts(conn, params) do
    search_query = Map.get(params, "search", "")
    page = SafeConvert.parse_page(params)
    per_page = 20

    {multi_account_data, total_count} =
      if search_query != "" do
        Accounts.search_multi_accounts_paginated(search_query, page, per_page)
      else
        Accounts.detect_multi_accounts_paginated(page, per_page)
      end

    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)

    render(conn, :multi_accounts,
      multi_account_data: multi_account_data,
      search_query: search_query,
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range
    )
  end

  def lookup_ip(conn, %{"ip" => ip}) do
    case Elektrine.IpLookup.lookup(ip) do
      {:ok, data} ->
        json(conn, %{success: true, data: data})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: reason})
    end
  end

  def new(conn, _params) do
    changeset = Accounts.change_user_admin_registration(%Accounts.User{}, %{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.admin_create_user(user_params) do
      {:ok, user} ->
        # Log the admin action
        Elektrine.AuditLog.log(
          conn.assigns.current_user.id,
          "create",
          "user",
          target_user_id: user.id,
          details: %{username: user.username, is_admin: user.is_admin},
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(:info, "User #{user.username} created successfully.")
        |> redirect(to: ~p"/pripyat/users")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end

  def edit(conn, %{"id" => id}) do
    user_data = Accounts.get_user_with_ip_info!(id)
    changeset = Accounts.change_user_admin(user_data.user)

    # Get user's email aliases
    aliases = Elektrine.Email.list_aliases(user_data.user.id)

    render(conn, :edit,
      user: user_data.user,
      changeset: changeset,
      related_by_registration: user_data.related_by_registration,
      aliases: aliases
    )
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    user_data = Accounts.get_user_with_ip_info!(id)

    # Convert checkbox values from "on"/"off" to boolean
    normalized_params =
      user_params
      |> Map.update("verified", false, fn
        "true" -> true
        _ -> false
      end)
      |> Map.update("banned", false, fn
        "on" -> true
        _ -> false
      end)
      |> Map.update("suspended", false, fn
        "on" -> true
        _ -> false
      end)
      |> Map.update("trust_level_locked", false, fn
        "true" -> true
        _ -> false
      end)
      |> Map.update("trust_level", nil, fn
        value when is_binary(value) -> String.to_integer(value)
        value -> value
      end)

    # Track if trust level was manually changed
    old_level = user_data.user.trust_level
    new_level = normalized_params["trust_level"]
    trust_level_changed = new_level && new_level != old_level

    case Accounts.admin_update_user(user_data.user, normalized_params) do
      {:ok, updated_user} ->
        # Log trust level change if it occurred
        if trust_level_changed do
          Elektrine.Accounts.TrustLevel.promote_user(
            updated_user,
            new_level,
            "manual",
            conn.assigns.current_user.id,
            "Manually set by admin"
          )
        end

        conn
        |> put_flash(:info, "User updated successfully.")
        |> redirect(to: ~p"/pripyat/users")

      {:error, changeset} ->
        render(conn, :edit,
          user: user_data.user,
          changeset: changeset,
          related_by_registration: user_data.related_by_registration
        )
    end
  end

  def ban(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)

    # Prevent banning admin users
    if user.is_admin do
      conn
      |> put_flash(:error, "Admin users cannot be banned.")
      |> redirect(to: ~p"/pripyat/users")
    else
      render(conn, :ban, user: user)
    end
  end

  def confirm_ban(conn, %{"id" => id, "ban" => ban_params}) do
    user = Accounts.get_user!(id)

    # Prevent banning admin users
    if user.is_admin do
      conn
      |> put_flash(:error, "Admin users cannot be banned.")
      |> redirect(to: ~p"/pripyat/users")
    else
      case Accounts.ban_user(user, ban_params) do
        {:ok, _banned_user} ->
          # Log the ban action
          Elektrine.AuditLog.log(
            conn.assigns.current_user.id,
            "ban",
            "user",
            target_user_id: user.id,
            details: %{username: user.username, reason: ban_params["reason"]},
            ip_address: get_remote_ip(conn),
            user_agent: get_req_header(conn, "user-agent") |> List.first()
          )

          conn
          |> put_flash(:info, "User has been banned successfully.")
          |> redirect(to: ~p"/pripyat/users")

        {:error, _changeset} ->
          conn
          |> put_flash(:error, "Failed to ban user.")
          |> redirect(to: ~p"/pripyat/users")
      end
    end
  end

  def unban(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)

    case Accounts.unban_user(user) do
      {:ok, _unbanned_user} ->
        # Log the unban action
        Elektrine.AuditLog.log(
          conn.assigns.current_user.id,
          "unban",
          "user",
          target_user_id: user.id,
          details: %{username: user.username},
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        # Determine redirect based on where the request came from
        redirect_path =
          case get_req_header(conn, "referer") do
            [referer] when is_binary(referer) ->
              if String.contains?(referer, "/admin/users/#{id}/edit") do
                ~p"/pripyat/users/#{id}/edit"
              else
                ~p"/pripyat/users"
              end

            _ ->
              ~p"/pripyat/users"
          end

        conn
        |> put_flash(:info, "User has been unbanned successfully.")
        |> redirect(to: redirect_path)

      {:error, _changeset} ->
        # Determine redirect based on where the request came from
        redirect_path =
          case get_req_header(conn, "referer") do
            [referer] when is_binary(referer) ->
              if String.contains?(referer, "/admin/users/#{id}/edit") do
                ~p"/pripyat/users/#{id}/edit"
              else
                ~p"/pripyat/users"
              end

            _ ->
              ~p"/pripyat/users"
          end

        conn
        |> put_flash(:error, "Failed to unban user.")
        |> redirect(to: redirect_path)
    end
  end

  def suspend(conn, %{"id" => id} = params) do
    user = Accounts.get_user!(id)

    # Prevent suspending admin users
    if user.is_admin do
      conn
      |> put_flash(:error, "Admin users cannot be suspended.")
      |> redirect(to: ~p"/pripyat/users/#{id}/edit")
    else
      suspend_params = %{
        "suspended" => true,
        "suspended_until" => params["suspended_until"],
        "suspension_reason" => params["suspension_reason"] || "Suspended by administrator"
      }

      case Accounts.suspend_user(user, suspend_params) do
        {:ok, _suspended_user} ->
          # Log the suspend action
          Elektrine.AuditLog.log(
            conn.assigns.current_user.id,
            "suspend",
            "user",
            target_user_id: user.id,
            details: %{
              username: user.username,
              suspended_until: suspend_params["suspended_until"],
              reason: suspend_params["suspension_reason"]
            },
            ip_address: get_remote_ip(conn),
            user_agent: get_req_header(conn, "user-agent") |> List.first()
          )

          conn
          |> put_flash(:info, "User has been suspended successfully.")
          |> redirect(to: ~p"/pripyat/users/#{id}/edit")

        {:error, :cannot_ban_admin} ->
          conn
          |> put_flash(:error, "Admin users cannot be suspended.")
          |> redirect(to: ~p"/pripyat/users/#{id}/edit")

        {:error, _changeset} ->
          conn
          |> put_flash(:error, "Failed to suspend user.")
          |> redirect(to: ~p"/pripyat/users/#{id}/edit")
      end
    end
  end

  def unsuspend(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)

    case Accounts.unsuspend_user(user) do
      {:ok, _unsuspended_user} ->
        # Log the unsuspend action
        Elektrine.AuditLog.log(
          conn.assigns.current_user.id,
          "unsuspend",
          "user",
          target_user_id: user.id,
          details: %{username: user.username},
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(:info, "User suspension has been lifted successfully.")
        |> redirect(to: ~p"/pripyat/users/#{id}/edit")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to unsuspend user.")
        |> redirect(to: ~p"/pripyat/users/#{id}/edit")
    end
  end

  def impersonate(conn, %{"id" => id}) do
    target_user = Accounts.get_user!(id)
    admin_user = conn.assigns.current_user

    # Prevent impersonating other admin users
    if target_user.is_admin do
      conn
      |> put_flash(:error, "Cannot impersonate another admin user.")
      |> redirect(to: ~p"/pripyat/users/#{id}/edit")
    else
      # Log the impersonation action
      Elektrine.AuditLog.log(
        admin_user.id,
        "impersonate",
        "user",
        target_user_id: target_user.id,
        details: %{
          admin_username: admin_user.username,
          target_username: target_user.username
        },
        ip_address: get_remote_ip(conn),
        user_agent: get_req_header(conn, "user-agent") |> List.first()
      )

      # Store the original admin user ID in session for later restoration
      ElektrineWeb.UserAuth.log_in_user(conn, target_user, %{"remember_me" => "false"},
        flash:
          {:warning,
           "You are now impersonating #{target_user.username}. Use the admin menu to stop impersonation."},
        session: %{
          impersonating_admin_id: admin_user.id,
          impersonated_user_id: target_user.id
        }
      )
    end
  end

  def stop_impersonation(conn, _params) do
    # Only allow if currently impersonating
    if admin_id = get_session(conn, :impersonating_admin_id) do
      admin_user = Accounts.get_user!(admin_id)
      impersonated_user_id = get_session(conn, :impersonated_user_id)

      # Log the stop impersonation action
      Elektrine.AuditLog.log(
        admin_id,
        "stop_impersonate",
        "user",
        target_user_id: impersonated_user_id,
        details: %{
          admin_username: admin_user.username
        },
        ip_address: get_remote_ip(conn),
        user_agent: get_req_header(conn, "user-agent") |> List.first()
      )

      # Clear impersonation session and restore admin user
      # Note: log_in_user clears session anyway, so we just pass the flash
      ElektrineWeb.UserAuth.log_in_user(conn, admin_user, %{"remember_me" => "false"},
        flash: {:info, "Impersonation ended. You are now logged in as yourself."}
      )
    else
      conn
      |> put_flash(:error, "You are not currently impersonating anyone.")
      |> redirect(to: ~p"/")
    end
  end

  def delete(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)

    cond do
      # Prevent admins from deleting themselves
      user.id == conn.assigns.current_user.id ->
        conn
        |> put_flash(:error, "You cannot delete your own account.")
        |> redirect(to: ~p"/pripyat/users")

      # Prevent deleting admin users
      user.is_admin ->
        conn
        |> put_flash(:error, "Admin users cannot be deleted.")
        |> redirect(to: ~p"/pripyat/users")

      true ->
        case Accounts.admin_delete_user(user) do
          {:ok, _deleted_user} ->
            # Log the deletion action
            Elektrine.AuditLog.log(
              conn.assigns.current_user.id,
              "delete",
              "user",
              details: %{username: user.username, user_id: user.id},
              ip_address: get_remote_ip(conn),
              user_agent: get_req_header(conn, "user-agent") |> List.first()
            )

            conn
            |> put_flash(:info, "User and all associated data deleted successfully.")
            |> redirect(to: ~p"/pripyat/users")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Failed to delete user.")
            |> redirect(to: ~p"/pripyat/users")
        end
    end
  end

  def reset_user_2fa(conn, %{"id" => user_id}) do
    admin = conn.assigns.current_user
    user = Accounts.get_user!(user_id)

    case Accounts.disable_two_factor(user) do
      {:ok, _updated_user} ->
        # Log the admin action
        Elektrine.AuditLog.log(
          admin.id,
          "reset_2fa",
          "user_security",
          target_user_id: user.id,
          details: %{
            username: user.username,
            reset_by_admin: admin.username
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(:info, "Two-factor authentication has been disabled for #{user.username}.")
        |> redirect(to: ~p"/pripyat/users/#{user.id}/edit")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to reset 2FA for #{user.username}.")
        |> redirect(to: ~p"/pripyat/users/#{user.id}/edit")
    end
  end

  def delete_user_alias(conn, %{"user_id" => user_id, "alias_id" => alias_id}) do
    user = Accounts.get_user!(user_id)
    alias_record = Email.get_alias(alias_id, user.id)

    case alias_record do
      nil ->
        conn
        |> put_flash(:error, "Alias not found.")
        |> redirect(to: ~p"/pripyat/users")

      alias_record ->
        case Email.delete_alias(alias_record) do
          {:ok, _deleted_alias} ->
            # Log the admin action
            Elektrine.AuditLog.log(
              conn.assigns.current_user.id,
              "delete",
              "alias",
              target_user_id: user.id,
              details: %{
                alias_email: alias_record.alias_email,
                target_email: alias_record.target_email,
                username: user.username
              },
              ip_address: get_remote_ip(conn),
              user_agent: get_req_header(conn, "user-agent") |> List.first()
            )

            conn
            |> put_flash(:info, "Alias #{alias_record.alias_email} deleted successfully.")
            |> redirect(to: ~p"/pripyat/users")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Failed to delete alias.")
            |> redirect(to: ~p"/pripyat/users")
        end
    end
  end

  def account_lookup(conn, _params) do
    render(conn, :account_lookup,
      search_results: nil,
      search_query: nil,
      search_type: "email"
    )
  end

  def search_accounts(conn, %{"search" => search_params}) do
    admin = conn.assigns.current_user
    search_query = String.trim(search_params["query"] || "")
    search_type = search_params["type"] || "email"

    # Check for exact match syntax (wrapped in quotes)
    is_exact_match =
      String.starts_with?(search_query, "\"") && String.ends_with?(search_query, "\"")

    clean_query =
      if is_exact_match do
        String.trim(search_query, "\"")
      else
        search_query
      end

    # Log the admin search action for security
    Elektrine.AuditLog.log(
      admin.id,
      "search",
      "account_investigation",
      details: %{
        search_query: clean_query,
        search_type: search_type,
        exact_match: is_exact_match
      },
      ip_address: get_remote_ip(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    )

    search_results =
      if String.length(clean_query) > 0 do
        if is_exact_match do
          perform_account_search_exact(clean_query, search_type)
        else
          perform_account_search(clean_query, search_type)
        end
      else
        []
      end

    render(conn, :account_lookup,
      search_results: search_results,
      search_query: search_query,
      search_type: search_type
    )
  end

  def reset_user_password(conn, %{"id" => user_id}) do
    admin = conn.assigns.current_user
    user = Accounts.get_user!(user_id)

    # Generate a secure temporary password
    temp_password = :crypto.strong_rand_bytes(12) |> Base.url_encode64() |> binary_part(0, 12)

    case Accounts.admin_reset_password(user, %{"password" => temp_password}) do
      {:ok, _user} ->
        # Log the admin action (don't store the password in audit log)
        Elektrine.AuditLog.log(
          admin.id,
          "reset_password",
          "user_account",
          target_user_id: user.id,
          details: %{
            reset_by_admin: admin.username
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(
          :info,
          "Password reset for #{user.username}. Temporary password: #{temp_password}"
        )
        |> redirect(to: ~p"/pripyat/users/#{user.id}/edit")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to reset password for #{user.username}")
        |> redirect(to: ~p"/pripyat/users/#{user.id}/edit")
    end
  end

  # Private helper functions

  defp get_all_users_paginated(page, per_page) do
    offset = (page - 1) * per_page

    query =
      from(u in Accounts.User,
        order_by: [desc: u.inserted_at],
        select: [
          :id,
          :username,
          :handle,
          :display_name,
          :unique_id,
          :avatar,
          :is_admin,
          :banned,
          :inserted_at,
          :registration_ip,
          :last_login_ip,
          :last_login_at,
          :login_count,
          :two_factor_enabled,
          :suspended,
          :suspended_until
        ]
      )

    total_count = Repo.aggregate(Accounts.User, :count, :id)

    users =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {users, total_count}
  end

  defp search_users_exact(search_query, page, per_page) do
    offset = (page - 1) * per_page

    query =
      from(u in Accounts.User,
        where: u.username == ^search_query,
        order_by: [desc: u.inserted_at],
        select: [
          :id,
          :username,
          :handle,
          :display_name,
          :unique_id,
          :avatar,
          :is_admin,
          :banned,
          :inserted_at,
          :registration_ip,
          :last_login_ip,
          :last_login_at,
          :login_count,
          :two_factor_enabled,
          :suspended,
          :suspended_until
        ]
      )

    users = query |> limit(^per_page) |> offset(^offset) |> Repo.all()
    total_count = Repo.aggregate(query, :count, :id)
    {users, total_count}
  end

  defp search_users_paginated(search_query, page, per_page) do
    offset = (page - 1) * per_page
    search_term = "%#{search_query}%"

    query =
      from(u in Accounts.User,
        where:
          ilike(u.username, ^search_term) or ilike(u.handle, ^search_term) or
            ilike(u.registration_ip, ^search_term) or ilike(u.last_login_ip, ^search_term),
        order_by: [desc: u.inserted_at],
        select: [
          :id,
          :username,
          :handle,
          :display_name,
          :unique_id,
          :avatar,
          :is_admin,
          :banned,
          :inserted_at,
          :registration_ip,
          :last_login_ip,
          :last_login_at,
          :login_count,
          :two_factor_enabled,
          :suspended,
          :suspended_until
        ]
      )

    total_count =
      from(u in Accounts.User,
        where:
          ilike(u.username, ^search_term) or ilike(u.handle, ^search_term) or
            ilike(u.registration_ip, ^search_term) or ilike(u.last_login_ip, ^search_term)
      )
      |> Repo.aggregate(:count, :id)

    users =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {users, total_count}
  end

  defp get_unique_registration_ip_count do
    from(u in Elektrine.Accounts.User,
      where: not is_nil(u.registration_ip),
      select: count(fragment("DISTINCT ?", u.registration_ip))
    )
    |> Elektrine.Repo.one()
    |> Kernel.||(0)
  end

  defp get_unique_login_ip_count do
    from(u in Elektrine.Accounts.User,
      where: not is_nil(u.last_login_ip),
      select: count(fragment("DISTINCT ?", u.last_login_ip))
    )
    |> Elektrine.Repo.one()
    |> Kernel.||(0)
  end

  defp perform_account_search_exact(query, "email") do
    import Ecto.Query

    # Search mailboxes for exact match
    mailboxes =
      from(m in Email.Mailbox,
        where: m.email == ^query,
        preload: [:user],
        order_by: [desc: m.inserted_at]
      )
      |> Repo.all()

    # Search aliases for exact match
    aliases =
      from(a in Email.Alias,
        where: a.alias_email == ^query or a.target_email == ^query,
        preload: [:user],
        order_by: [desc: a.inserted_at]
      )
      |> Repo.all()

    # Build results with user information
    mailbox_results =
      Enum.map(mailboxes, fn mailbox ->
        %{
          type: :mailbox,
          email: mailbox.email,
          user: mailbox.user,
          created_at: mailbox.inserted_at,
          details: %{
            forward_to: mailbox.forward_to,
            forward_enabled: mailbox.forward_enabled
          }
        }
      end)

    alias_results =
      Enum.map(aliases, fn alias_record ->
        %{
          type: :alias,
          email: alias_record.alias_email,
          user: alias_record.user,
          created_at: alias_record.inserted_at,
          details: %{
            target_email: alias_record.target_email,
            enabled: alias_record.enabled
          }
        }
      end)

    mailbox_results ++ alias_results
  end

  defp perform_account_search_exact(query, "username") do
    import Ecto.Query

    # Find user by exact username match
    users =
      from(u in Accounts.User,
        where: u.username == ^query,
        order_by: [desc: u.inserted_at]
      )
      |> Repo.all()

    # For each user, get their mailboxes and aliases
    Enum.flat_map(users, fn user ->
      mailboxes = Email.list_mailboxes(user.id)
      aliases = Email.list_aliases(user.id)

      mailbox_results =
        Enum.map(mailboxes, fn mailbox ->
          %{
            type: :mailbox,
            email: mailbox.email,
            user: user,
            created_at: mailbox.inserted_at,
            details: %{
              forward_to: mailbox.forward_to,
              forward_enabled: mailbox.forward_enabled
            }
          }
        end)

      alias_results =
        Enum.map(aliases, fn alias_record ->
          %{
            type: :alias,
            email: alias_record.alias_email,
            user: user,
            created_at: alias_record.inserted_at,
            details: %{
              target_email: alias_record.target_email,
              enabled: alias_record.enabled
            }
          }
        end)

      mailbox_results ++ alias_results
    end)
  end

  defp perform_account_search_exact(query, "ip") do
    import Ecto.Query

    # Find users by exact IP match
    users =
      from(u in Accounts.User,
        where: u.registration_ip == ^query or u.last_login_ip == ^query,
        order_by: [desc: u.inserted_at]
      )
      |> Repo.all()

    # For each user, get their mailboxes
    Enum.flat_map(users, fn user ->
      mailboxes = Email.list_mailboxes(user.id)

      Enum.map(mailboxes, fn mailbox ->
        %{
          type: :mailbox,
          email: mailbox.email,
          user: user,
          created_at: mailbox.inserted_at,
          details: %{
            registration_ip: user.registration_ip,
            last_login_ip: user.last_login_ip,
            forward_to: mailbox.forward_to
          }
        }
      end)
    end)
  end

  defp perform_account_search(query, "email") do
    import Ecto.Query
    search_pattern = "%#{query}%"

    # Search mailboxes for fuzzy match
    mailboxes =
      from(m in Email.Mailbox,
        where: ilike(m.email, ^search_pattern),
        preload: [:user],
        order_by: [desc: m.inserted_at],
        limit: 50
      )
      |> Repo.all()

    # Search aliases for fuzzy match
    aliases =
      from(a in Email.Alias,
        where: ilike(a.alias_email, ^search_pattern) or ilike(a.target_email, ^search_pattern),
        preload: [:user],
        order_by: [desc: a.inserted_at],
        limit: 50
      )
      |> Repo.all()

    # Build results with user information
    mailbox_results =
      Enum.map(mailboxes, fn mailbox ->
        %{
          type: :mailbox,
          email: mailbox.email,
          user: mailbox.user,
          created_at: mailbox.inserted_at,
          details: %{
            forward_to: mailbox.forward_to,
            forward_enabled: mailbox.forward_enabled
          }
        }
      end)

    alias_results =
      Enum.map(aliases, fn alias_record ->
        %{
          type: :alias,
          email: alias_record.alias_email,
          user: alias_record.user,
          created_at: alias_record.inserted_at,
          details: %{
            target_email: alias_record.target_email,
            enabled: alias_record.enabled
          }
        }
      end)

    (mailbox_results ++ alias_results) |> Enum.take(50)
  end

  defp perform_account_search(query, "username") do
    import Ecto.Query
    search_pattern = "%#{query}%"

    # Find users by fuzzy username match
    users =
      from(u in Accounts.User,
        where: ilike(u.username, ^search_pattern),
        order_by: [desc: u.inserted_at],
        limit: 20
      )
      |> Repo.all()

    # For each user, get their mailboxes and aliases
    Enum.flat_map(users, fn user ->
      mailboxes = Email.list_mailboxes(user.id)
      aliases = Email.list_aliases(user.id)

      mailbox_results =
        Enum.map(mailboxes, fn mailbox ->
          %{
            type: :mailbox,
            email: mailbox.email,
            user: user,
            created_at: mailbox.inserted_at,
            details: %{
              forward_to: mailbox.forward_to,
              forward_enabled: mailbox.forward_enabled
            }
          }
        end)

      alias_results =
        Enum.map(aliases, fn alias_record ->
          %{
            type: :alias,
            email: alias_record.alias_email,
            user: user,
            created_at: alias_record.inserted_at,
            details: %{
              target_email: alias_record.target_email,
              enabled: alias_record.enabled
            }
          }
        end)

      mailbox_results ++ alias_results
    end)
    |> Enum.take(50)
  end

  defp perform_account_search(query, "ip") do
    import Ecto.Query
    search_pattern = "%#{query}%"

    # Find users by fuzzy IP match
    users =
      from(u in Accounts.User,
        where:
          ilike(u.registration_ip, ^search_pattern) or ilike(u.last_login_ip, ^search_pattern),
        order_by: [desc: u.inserted_at],
        limit: 20
      )
      |> Repo.all()

    # For each user, get their mailboxes
    Enum.flat_map(users, fn user ->
      mailboxes = Email.list_mailboxes(user.id)

      Enum.map(mailboxes, fn mailbox ->
        %{
          type: :mailbox,
          email: mailbox.email,
          user: user,
          created_at: mailbox.inserted_at,
          details: %{
            registration_ip: user.registration_ip,
            last_login_ip: user.last_login_ip,
            forward_to: mailbox.forward_to
          }
        }
      end)
    end)
    |> Enum.take(50)
  end

  defp perform_account_search(_query, _type), do: []

  defp pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..total_pages//1 |> Enum.to_list()
  end

  defp pagination_range(current_page, total_pages) do
    cond do
      current_page <= 4 ->
        1..7//1 |> Enum.to_list()

      current_page >= total_pages - 3 ->
        (total_pages - 6)..total_pages//1 |> Enum.to_list()

      true ->
        (current_page - 3)..(current_page + 3)//1 |> Enum.to_list()
    end
  end

  defp get_remote_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end
end
