defmodule ElektrineWeb.UserSettingsController do
  use ElektrineWeb, :controller
  require Logger

  alias Elektrine.Accounts
  alias Elektrine.Auth.RateLimiter

  plug :assign_user

  def edit(conn, _params) do
    user = conn.assigns.current_user
    changeset = Accounts.change_user(user)
    pending_deletion = Accounts.get_pending_deletion_request(user)
    render(conn, :edit, changeset: changeset, pending_deletion: pending_deletion)
  end

  def update(conn, %{"user" => user_params}) do
    user = conn.assigns.current_user

    # Handle avatar upload if present
    {user_params, upload_error} = handle_avatar_upload(user_params, user)

    case {upload_error, Accounts.update_user(user, user_params)} do
      {nil, {:ok, _user}} ->
        conn
        |> put_flash(:info, "User updated successfully.")
        |> redirect(to: ~p"/account")

      {upload_error, {:ok, _user}} when upload_error != nil ->
        conn
        |> put_flash(:error, upload_error)
        |> redirect(to: ~p"/account")

      {upload_error, {:error, changeset}} ->
        conn = if upload_error, do: put_flash(conn, :error, upload_error), else: conn
        pending_deletion = Accounts.get_pending_deletion_request(user)
        render(conn, :edit, changeset: changeset, pending_deletion: pending_deletion)
    end
  end

  def edit_password(conn, _params) do
    user = conn.assigns.current_user
    changeset = Accounts.change_user_password(user)
    render(conn, :edit_password, changeset: changeset)
  end

  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_user

    # Require 2FA verification if user has 2FA enabled
    case verify_2fa_for_password_change(user, user_params) do
      :ok ->
        case Accounts.update_user_password(user, user_params) do
          {:ok, _user} ->
            conn
            |> put_flash(:info, "Password updated successfully.")
            |> redirect(to: ~p"/account")

          {:error, changeset} ->
            render(conn, :edit_password, changeset: changeset)
        end

      {:error, reason} ->
        changeset =
          Accounts.change_user_password(user, user_params)
          |> Ecto.Changeset.add_error(:two_factor_code, reason)

        render(conn, :edit_password, changeset: changeset)
    end
  end

  def delete(conn, _params) do
    render(conn, :delete)
  end

  def confirm_delete(conn, %{"confirmation" => confirmation, "reason" => reason}) do
    user = conn.assigns.current_user

    if confirmation == user.username do
      # Check if user already has a pending deletion request
      case Accounts.get_pending_deletion_request(user) do
        nil ->
          # Create new deletion request
          case Accounts.create_deletion_request(user, %{reason: reason}) do
            {:ok, _request} ->
              conn
              |> put_flash(
                :info,
                "Your account deletion request has been submitted and is pending admin approval."
              )
              |> redirect(to: ~p"/account")

            {:error, _changeset} ->
              conn
              |> put_flash(
                :error,
                "There was an error submitting your deletion request. Please try again."
              )
              |> redirect(to: ~p"/account/delete")
          end

        _existing_request ->
          conn
          |> put_flash(:error, "You already have a pending account deletion request.")
          |> redirect(to: ~p"/account")
      end
    else
      conn
      |> put_flash(:error, "Username confirmation does not match. Request not submitted.")
      |> redirect(to: ~p"/account/delete")
    end
  end

  def confirm_delete(conn, %{"confirmation" => confirmation}) do
    # Handle case where reason is not provided
    confirm_delete(conn, %{"confirmation" => confirmation, "reason" => ""})
  end

  def two_factor_setup(conn, params) do
    user = conn.assigns.current_user

    if user.two_factor_enabled do
      redirect(conn, to: ~p"/account/two_factor")
    else
      # Force regeneration if requested or if no secret in session
      force_new = params["refresh"] == "true" || !get_session(conn, :two_factor_setup_secret)

      if force_new do
        case Accounts.initiate_two_factor_setup(user) do
          {:ok, setup_data} ->
            # Generate QR code inline to avoid session timing issues
            qr_code_data_uri =
              case Accounts.TwoFactor.generate_qr_code_data_uri(setup_data.provisioning_uri) do
                {:ok, data_uri} -> data_uri
                {:error, _} -> nil
              end

            conn
            # Clear old session data
            |> delete_session(:two_factor_setup_secret)
            |> delete_session(:two_factor_setup_backup_codes_plain)
            |> delete_session(:two_factor_setup_backup_codes_hashed)
            |> put_session(:two_factor_setup_secret, setup_data.secret)
            # Store both plain (for display) and hashed (for database) in session
            |> put_session(:two_factor_setup_backup_codes_plain, setup_data.plain_backup_codes)
            |> put_session(:two_factor_setup_backup_codes_hashed, setup_data.hashed_backup_codes)
            |> render(:two_factor_setup,
              page_title: "Two-Factor Setup",
              secret: setup_data.secret,
              # Show plain codes to user
              backup_codes: setup_data.plain_backup_codes,
              provisioning_uri: setup_data.provisioning_uri,
              qr_code_data_uri: qr_code_data_uri,
              error: nil
            )

          {:error, _} ->
            conn
            |> put_flash(:error, "Failed to initialize two-factor authentication setup.")
            |> redirect(to: ~p"/account")
        end
      else
        # Use existing session data
        secret = get_session(conn, :two_factor_setup_secret)
        plain_backup_codes = get_session(conn, :two_factor_setup_backup_codes_plain)
        provisioning_uri = Accounts.TwoFactor.generate_provisioning_uri(secret, user.username)

        # Generate QR code inline to avoid session timing issues
        qr_code_data_uri =
          case Accounts.TwoFactor.generate_qr_code_data_uri(provisioning_uri) do
            {:ok, data_uri} -> data_uri
            {:error, _} -> nil
          end

        render(conn, :two_factor_setup,
          page_title: "Two-Factor Setup",
          secret: secret,
          # Show plain codes to user
          backup_codes: plain_backup_codes,
          provisioning_uri: provisioning_uri,
          qr_code_data_uri: qr_code_data_uri,
          error: nil
        )
      end
    end
  end

  def two_factor_enable(conn, %{"two_factor" => %{"code" => code}}) do
    require Logger

    user = conn.assigns.current_user
    secret = get_session(conn, :two_factor_setup_secret)
    hashed_backup_codes = get_session(conn, :two_factor_setup_backup_codes_hashed)
    plain_backup_codes = get_session(conn, :two_factor_setup_backup_codes_plain)

    if secret && hashed_backup_codes do
      # Use hashed codes for database storage
      case Accounts.enable_two_factor(user, secret, hashed_backup_codes, code) do
        {:ok, _updated_user} ->
          conn
          |> delete_session(:two_factor_setup_secret)
          |> delete_session(:two_factor_setup_backup_codes_plain)
          |> delete_session(:two_factor_setup_backup_codes_hashed)
          |> put_flash(:info, "Two-factor authentication has been enabled successfully!")
          |> redirect(to: ~p"/account")

        {:error, :invalid_totp_code} ->
          provisioning_uri =
            Elektrine.Accounts.TwoFactor.generate_provisioning_uri(secret, user.username)

          qr_code_data_uri =
            case Elektrine.Accounts.TwoFactor.generate_qr_code_data_uri(provisioning_uri) do
              {:ok, data_uri} -> data_uri
              {:error, _} -> nil
            end

          conn
          |> put_flash(:error, "Invalid authentication code. Please try again.")
          |> render(:two_factor_setup,
            page_title: "Two-Factor Setup",
            secret: secret,
            backup_codes: plain_backup_codes,
            provisioning_uri: provisioning_uri,
            qr_code_data_uri: qr_code_data_uri,
            error: "Invalid authentication code"
          )

        {:error, :database_unavailable} ->
          Logger.error("2FA Enable: Database unavailable")

          conn
          |> put_flash(:error, "Database temporarily unavailable. Please try again.")
          |> redirect(to: ~p"/account/two_factor/setup")

        {:error, :database_exception} ->
          Logger.error("2FA Enable: Database exception")

          conn
          |> put_flash(:error, "Database error occurred. Please try again.")
          |> redirect(to: ~p"/account/two_factor/setup")

        {:error, :invalid_changeset} ->
          Logger.error("2FA Enable: Invalid changeset")

          conn
          |> put_flash(:error, "Invalid data for two-factor setup. Please try again.")
          |> redirect(to: ~p"/account/two_factor/setup")

        {:error, reason} ->
          Logger.error("2FA Enable: Other error - #{inspect(reason)}")

          conn
          |> put_flash(:error, "Failed to enable two-factor authentication.")
          |> redirect(to: ~p"/account")
      end
    else
      conn
      |> put_flash(:error, "Two-factor authentication setup session expired.")
      |> redirect(to: ~p"/account/two_factor/setup")
    end
  rescue
    exception ->
      Logger.error("2FA Enable: Exception occurred - #{inspect(exception)}")
      Logger.error("2FA Enable: Stacktrace - #{Exception.format_stacktrace(__STACKTRACE__)}")

      conn
      |> put_flash(:error, "An error occurred while enabling two-factor authentication.")
      |> redirect(to: ~p"/account")
  end

  def two_factor_enable(conn, params) do
    require Logger
    Logger.error("2FA Enable: Unexpected params format - keys=#{inspect(Map.keys(params))}")

    conn
    |> put_flash(:error, "Invalid request format for two-factor authentication.")
    |> redirect(to: ~p"/account/two_factor/setup")
  end

  def two_factor_manage(conn, _params) do
    user = conn.assigns.current_user

    if user.two_factor_enabled do
      backup_codes_count = length(user.two_factor_backup_codes || [])

      render(conn, :two_factor_manage,
        page_title: "Two-Factor Authentication",
        backup_codes_count: backup_codes_count
      )
    else
      redirect(conn, to: ~p"/account/two_factor/setup")
    end
  end

  def two_factor_disable(conn, %{
        "two_factor" => %{"code" => code, "current_password" => password}
      }) do
    user = conn.assigns.current_user
    identifier = "2fa_disable:#{user.id}"

    # SECURITY: Check rate limit before attempting to disable 2FA
    case RateLimiter.check_rate_limit(identifier) do
      {:ok, :allowed} ->
        with {:ok, _verified_user} <- Accounts.authenticate_user(user.username, password),
             {:ok, _} <- Accounts.verify_totp_only(user, code),
             {:ok, _updated_user} <- Accounts.disable_two_factor(user) do
          # Clear rate limiting on successful disable
          RateLimiter.record_successful_attempt(identifier)
          Logger.info("2FA successfully disabled for user #{user.id} (#{user.username})")

          conn
          |> put_flash(:info, "Two-factor authentication has been disabled.")
          |> redirect(to: ~p"/account")
        else
          {:error, :invalid_credentials} ->
            # Record failed attempt for password failure
            RateLimiter.record_failed_attempt(identifier)

            Logger.warning(
              "Failed 2FA disable attempt (invalid password) for user #{user.id} (#{user.username})"
            )

            conn
            |> put_flash(:error, "Invalid password.")
            |> redirect(to: ~p"/account/two_factor")

          {:error, :invalid_code} ->
            # Record failed attempt for invalid 2FA code
            RateLimiter.record_failed_attempt(identifier)

            Logger.warning(
              "Failed 2FA disable attempt (invalid code) for user #{user.id} (#{user.username})"
            )

            conn
            |> put_flash(:error, "Invalid authentication code.")
            |> redirect(to: ~p"/account/two_factor")

          {:error, _reason} ->
            # Record failed attempt for any other error
            RateLimiter.record_failed_attempt(identifier)
            Logger.warning("Failed 2FA disable attempt for user #{user.id} (#{user.username})")

            conn
            |> put_flash(:error, "Failed to disable two-factor authentication.")
            |> redirect(to: ~p"/account/two_factor")
        end

      {:error, {:rate_limited, retry_after, _reason}} ->
        minutes = div(retry_after, 60)
        time_msg = if minutes > 0, do: "#{minutes} minute(s)", else: "#{retry_after} second(s)"

        Logger.warning("2FA disable rate limit exceeded for user #{user.id} (#{user.username})")

        conn
        |> put_flash(:error, "Too many failed attempts. Please try again in #{time_msg}.")
        |> redirect(to: ~p"/account/two_factor")
    end
  end

  def two_factor_regenerate_codes(conn, %{"two_factor" => %{"code" => code}}) do
    user = conn.assigns.current_user
    identifier = "2fa_regen:#{user.id}"

    # SECURITY: Check rate limit before attempting to regenerate backup codes
    case RateLimiter.check_rate_limit(identifier) do
      {:ok, :allowed} ->
        with {:ok, _} <- Accounts.verify_two_factor_code(user, code),
             {:ok, {_updated_user, new_backup_codes}} <- Accounts.regenerate_backup_codes(user) do
          # Clear rate limiting on successful regeneration
          RateLimiter.record_successful_attempt(identifier)
          Logger.info("2FA backup codes regenerated for user #{user.id} (#{user.username})")

          render(conn, :two_factor_new_codes,
            page_title: "New Backup Codes",
            backup_codes: new_backup_codes
          )
        else
          {:error, :invalid_code} ->
            # Record failed attempt for invalid 2FA code
            RateLimiter.record_failed_attempt(identifier)

            Logger.warning(
              "Failed 2FA backup code regeneration (invalid code) for user #{user.id} (#{user.username})"
            )

            conn
            |> put_flash(:error, "Invalid authentication code.")
            |> redirect(to: ~p"/account/two_factor")

          {:error, _reason} ->
            # Record failed attempt for any other error
            RateLimiter.record_failed_attempt(identifier)

            Logger.warning(
              "Failed 2FA backup code regeneration for user #{user.id} (#{user.username})"
            )

            conn
            |> put_flash(:error, "Failed to regenerate backup codes.")
            |> redirect(to: ~p"/account/two_factor")
        end

      {:error, {:rate_limited, retry_after, _reason}} ->
        minutes = div(retry_after, 60)
        time_msg = if minutes > 0, do: "#{minutes} minute(s)", else: "#{retry_after} second(s)"

        Logger.warning(
          "2FA backup code regeneration rate limit exceeded for user #{user.id} (#{user.username})"
        )

        conn
        |> put_flash(:error, "Too many failed attempts. Please try again in #{time_msg}.")
        |> redirect(to: ~p"/account/two_factor")
    end
  end

  defp assign_user(conn, _opts) do
    assign(conn, :user, conn.assigns.current_user)
  end

  defp handle_avatar_upload(%{"avatar" => %Plug.Upload{} = upload} = user_params, user) do
    case Elektrine.Uploads.upload_avatar(upload, user.id) do
      {:ok, metadata} ->
        updated_params =
          user_params
          |> Map.put("avatar", metadata.key)
          |> Map.put("avatar_size", metadata.size)

        {updated_params, nil}

      {:error, {error_type, message}} ->
        error_message = format_upload_error(error_type, message)
        {Map.delete(user_params, "avatar"), error_message}

      {:error, reason} ->
        {Map.delete(user_params, "avatar"), "Failed to upload avatar: #{inspect(reason)}"}
    end
  end

  defp handle_avatar_upload(user_params, _user), do: {user_params, nil}

  defp format_upload_error(error_type, message) do
    case error_type do
      :file_too_large -> "Avatar upload failed: #{message}"
      :empty_file -> "Avatar upload failed: #{message}"
      :invalid_file_type -> "Avatar upload failed: #{message}"
      :invalid_extension -> "Avatar upload failed: #{message}"
      :malicious_content -> "Avatar upload failed: File contains potentially unsafe content"
      :image_too_wide -> "Avatar upload failed: #{message}"
      :image_too_tall -> "Avatar upload failed: #{message}"
      :invalid_image -> "Avatar upload failed: Invalid image file"
      _ -> "Avatar upload failed: #{message}"
    end
  end

  def two_factor_qr_code(conn, _params) do
    user = conn.assigns.current_user

    # Check if user already has 2FA enabled
    if user.two_factor_enabled do
      conn
      |> put_flash(:error, "Two-factor authentication is already enabled.")
      |> redirect(to: ~p"/account/two_factor")
    else
      # Get the secret from the session (same as setup page)
      secret = get_session(conn, :two_factor_setup_secret)

      if secret do
        username = user.username || user.email

        provisioning_uri =
          Elektrine.Accounts.TwoFactor.generate_provisioning_uri(secret, username)

        case Elektrine.Accounts.TwoFactor.generate_qr_code_png(provisioning_uri) do
          {:ok, png_binary} ->
            conn
            |> put_resp_content_type("image/png")
            |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
            |> put_resp_header("pragma", "no-cache")
            |> put_resp_header("expires", "0")
            |> send_resp(200, png_binary)

          {:error, _reason} ->
            conn
            |> put_flash(:error, "Failed to generate QR code.")
            |> redirect(to: ~p"/account/two_factor/setup")
        end
      else
        conn
        |> put_flash(
          :error,
          "Two-factor authentication session expired. Please start setup again."
        )
        |> redirect(to: ~p"/account/two_factor/setup")
      end
    end
  end

  def dismiss_announcement(conn, %{"id" => announcement_id}) do
    user = conn.assigns.current_user

    case Elektrine.Admin.dismiss_announcement_for_user(
           user.id,
           String.to_integer(announcement_id)
         ) do
      {:ok, _dismissal} ->
        conn
        |> redirect(to: get_referer_or_default(conn))

      {:error, _changeset} ->
        conn
        |> redirect(to: get_referer_or_default(conn))
    end
  end

  defp get_referer_or_default(conn) do
    case get_req_header(conn, "referer") do
      [referer] ->
        case URI.parse(referer) do
          %URI{path: path} when is_binary(path) and path != "" ->
            if String.starts_with?(path, "//"), do: "/", else: path

          _ ->
            "/"
        end

      [] ->
        "/"
    end
  end

  # Verify 2FA code for sensitive operations like password changes
  defp verify_2fa_for_password_change(user, user_params) do
    if user.two_factor_enabled do
      case Map.get(user_params, "two_factor_code") do
        nil ->
          {:error, "2FA code is required for password changes"}

        "" ->
          {:error, "2FA code is required for password changes"}

        code ->
          case Accounts.verify_totp_only(user, code) do
            {:ok, :totp} -> :ok
            {:error, :invalid_code} -> {:error, "Invalid 2FA code"}
            {:error, _} -> {:error, "2FA verification failed"}
          end
      end
    else
      # User doesn't have 2FA enabled, allow password change
      :ok
    end
  end

  @doc """
  Updates user status (online, away, dnd, offline) - no redirect.
  """
  def set_status(conn, params) do
    status = params["status"]
    user = conn.assigns.current_user

    if status in ["online", "away", "dnd", "offline"] do
      case Accounts.update_user_status(user, status) do
        {:ok, _updated_user} ->
          # Broadcast to the user's own channel
          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "user:#{user.id}",
            {:status_changed, status}
          )

          # Broadcast to all presence subscribers
          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "users",
            {:user_status_updated, user.id, status}
          )

          # Send 204 No Content - no redirect
          send_resp(conn, 204, "")

        {:error, _changeset} ->
          send_resp(conn, 400, "")
      end
    else
      send_resp(conn, 400, "")
    end
  end
end
