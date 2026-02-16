defmodule Elektrine.Accounts.Authentication do
  @moduledoc """
  Authentication context for user authentication, password management, and 2FA.
  Handles password verification, 2FA setup/verification, app passwords, and password recovery.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Accounts.{User, TwoFactor, AppPassword}
  alias Elektrine.Email.Mailbox

  require Logger

  ## Password Authentication

  @doc """
  Authenticates a user by username and password.

  Returns `{:ok, user}` if the username and password are valid,
  or `{:error, :invalid_credentials}` if the username or password are invalid.

  ## Examples

      iex> authenticate_user("username", "correct_password")
      {:ok, %User{}}

      iex> authenticate_user("username", "wrong_password")
      {:error, :invalid_credentials}

      iex> authenticate_user("nonexistent", "any_password")
      {:error, :invalid_credentials}

  """
  def authenticate_user(username, password) when is_binary(username) and is_binary(password) do
    user = get_user_by_username_case_insensitive(username)

    cond do
      is_nil(user) ->
        {:error, :invalid_credentials}

      user.banned ->
        {:error, {:banned, user.banned_reason}}

      user_suspended?(user) ->
        {:error, {:suspended, user.suspended_until, user.suspension_reason}}

      verify_password_hash(password, user.password_hash) ->
        # Rehash with Argon2 if the current hash is bcrypt
        if is_bcrypt_hash?(user.password_hash) do
          user
          |> User.password_changeset(%{password: password, password_confirmation: password})
          |> Repo.update()
        end

        # Check for expired suspensions and auto-unsuspend
        if user.suspended && user.suspended_until &&
             DateTime.compare(user.suspended_until, DateTime.utc_now()) == :lt do
          Elektrine.Accounts.Moderation.unsuspend_user(user)
        end

        {:ok, user}

      true ->
        {:error, :invalid_credentials}
    end
  end

  @doc """
  Verifies password for an existing user without re-querying the database.
  Use this when you already have the user struct loaded.
  Returns {:ok, user} if password is valid, {:error, reason} otherwise.
  """
  def verify_user_password(%User{} = user, password) when is_binary(password) do
    cond do
      user.banned ->
        {:error, {:banned, user.banned_reason}}

      user_suspended?(user) ->
        {:error, {:suspended, user.suspended_until, user.suspension_reason}}

      verify_password_hash(password, user.password_hash) ->
        {:ok, user}

      true ->
        {:error, :invalid_credentials}
    end
  end

  # Detects hash type and verifies password
  defp verify_password_hash(password, hash) do
    if is_bcrypt_hash?(hash),
      do: Bcrypt.verify_pass(password, hash),
      else: Argon2.verify_pass(password, hash)
  end

  # Simple heuristic to detect bcrypt hashes which start with "$2" or "$2a$"
  defp is_bcrypt_hash?(hash) when is_binary(hash) do
    String.starts_with?(hash, ["$2", "$2a$", "$2b$", "$2y$"])
  end

  defp is_bcrypt_hash?(_), do: false

  defp user_suspended?(%User{} = user) do
    user.suspended &&
      (is_nil(user.suspended_until) ||
         DateTime.compare(user.suspended_until, DateTime.utc_now()) == :gt)
  end

  @doc """
  Updates a user's password.

  ## Examples

      iex> update_user_password(user, %{password: "new password", password_confirmation: "new password"})
      {:ok, %User{}}

      iex> update_user_password(user, %{password: "invalid"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(%User{} = user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user password changes.
  """
  def change_user_password(%User{} = user, attrs \\ %{}) do
    User.password_changeset(user, attrs)
  end

  ## Two-Factor Authentication

  @doc """
  Initiates 2FA setup for a user by generating a secret and backup codes.

  Returns the secret and provisioning URI for QR code generation.
  """
  def initiate_two_factor_setup(%User{} = user) do
    try do
      secret = TwoFactor.generate_secret()
      {plain_codes, hashed_codes} = TwoFactor.generate_backup_codes()
      provisioning_uri = TwoFactor.generate_provisioning_uri(secret, user.username)

      # Return plain codes to show user, hashed codes for storage
      {:ok,
       %{
         secret: secret,
         # Show these to user once
         plain_backup_codes: plain_codes,
         # Store these in database
         hashed_backup_codes: hashed_codes,
         provisioning_uri: provisioning_uri
       }}
    rescue
      _ -> {:error, :setup_failed}
    end
  end

  @doc """
  Enables 2FA for a user after verifying the TOTP code.
  Expects hashed_backup_codes (not plain codes) for storage.
  """
  def enable_two_factor(%User{} = user, secret, hashed_backup_codes, totp_code) do
    # Check database connectivity first
    db_check =
      try do
        case Repo.query("SELECT 1", []) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error("2FA: Database connectivity check failed: #{inspect(reason)}")
            {:error, :database_unavailable}
        end
      rescue
        exception ->
          Logger.error("2FA: Database connectivity exception: #{inspect(exception)}")
          {:error, :database_exception}
      end

    case db_check do
      :ok ->
        if TwoFactor.verify_totp(secret, totp_code) do
          # Encode secret as Base64 for UTF-8 database storage
          encoded_secret = if is_binary(secret), do: Base.encode64(secret), else: secret

          changeset =
            User.enable_two_factor_changeset(user, %{
              two_factor_secret: encoded_secret,
              two_factor_backup_codes: hashed_backup_codes
            })

          if !changeset.valid? do
            Logger.error("2FA changeset errors: #{inspect(changeset.errors)}")
            {:error, :invalid_changeset}
          else
            try do
              case Repo.update(changeset) do
                {:ok, updated_user} ->
                  # Verify the update actually worked
                  case Repo.reload(updated_user) do
                    nil ->
                      Logger.error("2FA: User reload failed after update")
                      {:error, :reload_failed}

                    reloaded_user ->
                      {:ok, reloaded_user}
                  end

                {:error, changeset} ->
                  Logger.error("2FA database update failed: #{inspect(changeset.errors)}")
                  {:error, changeset}
              end
            rescue
              exception ->
                Logger.error("2FA: Database update exception: #{inspect(exception)}")
                {:error, :database_update_exception}
            end
          end
        else
          {:error, :invalid_totp_code}
        end

      {:error, reason} ->
        Logger.error("2FA: Database connectivity failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Disables 2FA for a user.
  """
  def disable_two_factor(%User{} = user) do
    user
    |> User.disable_two_factor_changeset()
    |> Repo.update()
  end

  @doc """
  Verifies a 2FA code (TOTP or backup code) for a user.
  """
  def verify_two_factor_code(%User{two_factor_enabled: true} = user, code) do
    # Decode Base64 secret for verification
    decoded_secret =
      if is_binary(user.two_factor_secret) do
        case Base.decode64(user.two_factor_secret) do
          {:ok, secret} -> secret
          # Fallback for existing non-encoded secrets
          :error -> user.two_factor_secret
        end
      else
        user.two_factor_secret
      end

    cond do
      TwoFactor.verify_totp(decoded_secret, code) ->
        {:ok, :totp}

      user.two_factor_backup_codes != nil ->
        case TwoFactor.verify_backup_code(user.two_factor_backup_codes, code) do
          {:ok, remaining_codes} ->
            # Update user with remaining backup codes
            user
            |> User.update_backup_codes_changeset(remaining_codes)
            |> Repo.update()

            {:ok, :backup_code}

          {:error, :invalid} ->
            {:error, :invalid_code}
        end

      true ->
        {:error, :invalid_code}
    end
  end

  def verify_two_factor_code(%User{two_factor_enabled: false}, _code) do
    {:error, :two_factor_not_enabled}
  end

  @doc """
  Verifies a TOTP code ONLY (not backup codes) for a user.
  This is used for sensitive operations like disabling 2FA where backup codes should not be allowed.
  """
  def verify_totp_only(%User{two_factor_enabled: true} = user, code) do
    # Decode Base64 secret for verification
    decoded_secret =
      if is_binary(user.two_factor_secret) do
        case Base.decode64(user.two_factor_secret) do
          {:ok, secret} -> secret
          # Fallback for existing non-encoded secrets
          :error -> user.two_factor_secret
        end
      else
        user.two_factor_secret
      end

    if TwoFactor.verify_totp(decoded_secret, code) do
      {:ok, :totp}
    else
      {:error, :invalid_code}
    end
  end

  def verify_totp_only(%User{two_factor_enabled: false}, _code) do
    {:error, :two_factor_not_enabled}
  end

  @doc """
  Regenerates backup codes for a user with 2FA enabled.
  Returns {:ok, {updated_user, plain_backup_codes}} so user can save them.
  """
  def regenerate_backup_codes(%User{two_factor_enabled: true} = user) do
    {plain_codes, hashed_codes} = TwoFactor.generate_backup_codes()

    result =
      user
      # Store hashed codes
      |> User.update_backup_codes_changeset(hashed_codes)
      |> Repo.update()

    case result do
      # Return plain codes to show user
      {:ok, updated_user} -> {:ok, {updated_user, plain_codes}}
      error -> error
    end
  end

  def regenerate_backup_codes(%User{two_factor_enabled: false}) do
    {:error, :two_factor_not_enabled}
  end

  @doc """
  Admin function to reset a user's 2FA (disable and clear all 2FA data).
  """
  def admin_reset_2fa(user) do
    user
    |> User.admin_2fa_reset_changeset()
    |> Repo.update()
  end

  ## App Passwords

  @doc """
  Lists all app passwords for a user.
  """
  def list_app_passwords(user_id) do
    AppPassword
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Creates a new app password for a user.
  Returns {:ok, app_password} with the raw token attached, or {:error, changeset}.
  """
  def create_app_password(user_id, attrs) do
    attrs = Map.put(attrs, :user_id, user_id)

    changeset = AppPassword.create_changeset(attrs)

    case Repo.insert(changeset) do
      {:ok, app_password} ->
        # Attach the raw token from the changeset
        token = changeset.changes[:token]
        {:ok, %{app_password | token: token}}

      error ->
        error
    end
  end

  @doc """
  Deletes an app password.
  """
  def delete_app_password(app_password_id, user_id) do
    AppPassword
    |> where(id: ^app_password_id, user_id: ^user_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      app_password -> Repo.delete(app_password)
    end
  end

  @doc """
  Authenticates a user with an app password.
  Returns:
    - {:ok, user} if valid
    - {:error, :user_not_found} if user doesn't exist
    - {:error, {:invalid_token, user}} if user exists but token is invalid
  """
  def authenticate_with_app_password(username, token) do
    # Clean the token (remove spaces/dashes if any)
    clean_token = String.replace(token, ~r/[\s-]/, "")

    case get_user_by_username_or_email(username) do
      {:ok, user} ->
        case verify_app_password(user.id, clean_token) do
          {:ok, _app_password} -> {:ok, user}
          {:error, _} -> {:error, {:invalid_token, user}}
        end

      {:error, _} ->
        {:error, :user_not_found}
    end
  end

  @doc """
  Verifies an app password token for a user.
  Updates last used timestamp if valid.
  """
  def verify_app_password(user_id, token, ip_address \\ nil) do
    token_hash = AppPassword.hash_token(token)

    AppPassword
    |> where(user_id: ^user_id, token_hash: ^token_hash)
    |> where([ap], is_nil(ap.expires_at) or ap.expires_at > ^DateTime.utc_now())
    |> Repo.one()
    |> case do
      nil ->
        {:error, :invalid_token}

      app_password ->
        # Update last used info
        {:ok, updated} =
          app_password
          |> AppPassword.update_last_used(ip_address)
          |> Repo.update()

        {:ok, updated}
    end
  end

  defp get_user_by_username_or_email(identifier) do
    normalized_identifier = String.trim(identifier || "")

    if String.contains?(normalized_identifier, "@") do
      case String.split(normalized_identifier, "@", parts: 2) do
        [username, domain] ->
          username = String.downcase(username)
          domain = String.downcase(domain)

          user =
            cond do
              domain in ["elektrine.com", "z.org"] ->
                get_user_by_username_case_insensitive(username)

              true ->
                get_user_by_mailbox_email(normalized_identifier)
            end

          if user, do: {:ok, user}, else: {:error, :not_found}

        _ ->
          {:error, :not_found}
      end
    else
      case get_user_by_username_case_insensitive(normalized_identifier) do
        nil -> {:error, :not_found}
        user -> {:ok, user}
      end
    end
  end

  defp get_user_by_mailbox_email(email_identifier) do
    normalized_email = String.downcase(email_identifier)

    User
    |> join(:inner, [u], m in Mailbox, on: m.user_id == u.id)
    |> where([_u, m], fragment("lower(?)", m.email) == ^normalized_email)
    |> limit(1)
    |> Repo.one()
  end

  # Case-insensitive username lookup
  defp get_user_by_username_case_insensitive(username) when is_binary(username) do
    User
    |> where([u], fragment("lower(?)", u.username) == ^String.downcase(username))
    |> Repo.one()
  end

  ## Password Recovery

  @doc """
  Updates a user's recovery email.
  """
  def update_recovery_email(%User{} = user, attrs) do
    user
    |> User.recovery_email_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Initiates a password reset by generating a token and sending email.
  Returns {:ok, user} if successful, even if no recovery email is set.
  If multiple users have the same recovery email, sends reset emails to all of them.
  """
  def initiate_password_reset(username_or_email) when is_binary(username_or_email) do
    users =
      case String.contains?(username_or_email, "@") do
        true ->
          get_users_by_recovery_email(username_or_email)

        false ->
          case Repo.get_by(User, username: username_or_email) do
            nil -> []
            user -> [user]
          end
      end

    case users do
      [] ->
        # No users found - return success to avoid username enumeration
        {:ok, :user_not_found}

      users_list ->
        # Process each user
        results =
          Enum.map(users_list, fn user ->
            case user do
              %User{is_admin: true} ->
                # SECURITY: Block password reset for admin accounts
                Logger.error(
                  "SECURITY ALERT: Attempted password reset for admin user: #{user.username}"
                )

                # Skip admin users silently
                {:ok, :admin_blocked}

              %User{recovery_email: recovery_email, recovery_email_verified: true}
              when not is_nil(recovery_email) ->
                token = generate_password_reset_token()

                case user
                     |> User.password_reset_changeset(token)
                     |> Repo.update() do
                  {:ok, updated_user} ->
                    # Send password reset email
                    send_password_reset_email(updated_user, token)
                    {:ok, updated_user}

                  {:error, changeset} ->
                    {:error, changeset}
                end

              %User{recovery_email: recovery_email, recovery_email_verified: verified}
              when not is_nil(recovery_email) and verified != true ->
                # User has recovery email but it's not verified
                {:error, :recovery_email_not_verified}

              %User{} ->
                # User exists but no recovery email set
                {:error, :no_recovery_email}
            end
          end)

        # Return success if at least one email was sent successfully
        if Enum.any?(results, fn
             {:ok, %User{}} -> true
             _ -> false
           end) do
          {:ok, :emails_sent}
        else
          # All failed or were blocked
          {:ok, :user_not_found}
        end
    end
  end

  @doc """
  Gets all users by recovery email (returns a list to handle potential duplicates).
  """
  def get_users_by_recovery_email(email) when is_binary(email) do
    from(u in User, where: u.recovery_email == ^email)
    |> Repo.all()
  end

  @doc """
  Gets a user by password reset token.
  """
  def get_user_by_password_reset_token(token) when is_binary(token) do
    Repo.get_by(User, password_reset_token: token)
  end

  @doc """
  Resets a user's password using a valid token.
  """
  def reset_password_with_token(token, attrs) when is_binary(token) do
    case get_user_by_password_reset_token(token) do
      %User{is_admin: true} = user ->
        # SECURITY: Block password reset completion for admin accounts
        Logger.error(
          "SECURITY ALERT: Attempted password reset completion for admin user: #{user.username}"
        )

        {:error, :invalid_token}

      %User{} = user ->
        if User.valid_password_reset_token?(user) do
          user
          |> User.password_reset_with_token_changeset(attrs)
          |> Repo.update()
        else
          {:error, :invalid_token}
        end

      nil ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Validates a password reset token without using it.
  """
  def validate_password_reset_token(token) when is_binary(token) do
    case get_user_by_password_reset_token(token) do
      %User{is_admin: true} = user ->
        # SECURITY: Block password reset token validation for admin accounts
        Logger.error(
          "SECURITY ALERT: Attempted password reset token validation for admin user: #{user.username}"
        )

        {:error, :invalid_token}

      %User{} = user ->
        if User.valid_password_reset_token?(user) do
          {:ok, user}
        else
          {:error, :invalid_token}
        end

      nil ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Clears a password reset token.
  """
  def clear_password_reset_token(%User{} = user) do
    user
    |> User.clear_password_reset_changeset()
    |> Repo.update()
  end

  @doc """
  Returns users whose passwords are older than the specified number of days.
  """
  def get_users_with_old_passwords(max_days) when is_integer(max_days) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-max_days, :day)

    from(u in User,
      where: not is_nil(u.last_password_change) and u.last_password_change < ^cutoff_date,
      select: [:id, :username, :email, :last_password_change, :is_admin],
      order_by: [asc: u.last_password_change]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of users whose passwords are older than the specified number of days.
  """
  def count_users_with_old_passwords(max_days) when is_integer(max_days) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-max_days, :day)

    from(u in User,
      where: not is_nil(u.last_password_change) and u.last_password_change < ^cutoff_date
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Admin function to reset a user's password with a new temporary password.
  """
  def admin_reset_password(user, attrs) do
    user
    |> User.admin_password_reset_changeset(attrs)
    |> Repo.update()
  end

  # Private helper functions

  defp generate_password_reset_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp send_password_reset_email(%User{recovery_email: recovery_email} = user, token)
       when not is_nil(recovery_email) do
    try do
      # Use the existing email infrastructure
      Elektrine.UserNotifier.password_reset_instructions(user, token)
      |> Elektrine.Mailer.deliver()
    rescue
      e ->
        Logger.error("Failed to send password reset email: #{inspect(e)}")
        {:error, :email_failed}
    end
  end

  defp send_password_reset_email(_, _), do: {:error, :no_recovery_email}
end
