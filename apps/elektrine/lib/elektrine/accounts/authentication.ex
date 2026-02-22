defmodule Elektrine.Accounts.Authentication do
  @moduledoc ~s|Authentication context for user authentication, password management, and 2FA.\nHandles password verification, 2FA setup/verification, app passwords, and password recovery.\n|
  import Ecto.Query, warn: false
  alias Elektrine.Accounts.{AppPassword, TwoFactor, User}
  alias Elektrine.Email.Mailbox
  alias Elektrine.Repo
  require Logger

  @doc ~s|Authenticates a user by username and password.\n\nReturns `{:ok, user}` if the username and password are valid,\nor `{:error, :invalid_credentials}` if the username or password are invalid.\n\n## Examples\n\n    iex> authenticate_user(\"username\", \"correct_password\")\n    {:ok, %User{}}\n\n    iex> authenticate_user(\"username\", \"wrong_password\")\n    {:error, :invalid_credentials}\n\n    iex> authenticate_user(\"nonexistent\", \"any_password\")\n    {:error, :invalid_credentials}\n\n|
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
        if bcrypt_hash?(user.password_hash) do
          user
          |> User.password_changeset(%{password: password, password_confirmation: password})
          |> Repo.update()
        end

        if user.suspended && user.suspended_until &&
             DateTime.compare(user.suspended_until, DateTime.utc_now()) == :lt do
          Elektrine.Accounts.Moderation.unsuspend_user(user)
        end

        {:ok, user}

      true ->
        {:error, :invalid_credentials}
    end
  end

  @doc ~s|Verifies password for an existing user without re-querying the database.\nUse this when you already have the user struct loaded.\nReturns {:ok, user} if password is valid, {:error, reason} otherwise.\n|
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

  defp verify_password_hash(password, hash) do
    if bcrypt_hash?(hash) do
      Bcrypt.verify_pass(password, hash)
    else
      Argon2.verify_pass(password, hash)
    end
  end

  defp bcrypt_hash?(hash) when is_binary(hash) do
    String.starts_with?(hash, ["$2", "$2a$", "$2b$", "$2y$"])
  end

  defp bcrypt_hash?(_) do
    false
  end

  defp user_suspended?(%User{} = user) do
    user.suspended &&
      (is_nil(user.suspended_until) ||
         DateTime.compare(user.suspended_until, DateTime.utc_now()) == :gt)
  end

  @doc ~s|Updates a user's password.\n\n## Examples\n\n    iex> update_user_password(user, %{password: \"new password\", password_confirmation: \"new password\"})\n    {:ok, %User{}}\n\n    iex> update_user_password(user, %{password: \"invalid\"})\n    {:error, %Ecto.Changeset{}}\n\n|
  def update_user_password(%User{} = user, attrs) do
    user |> User.password_changeset(attrs) |> Repo.update()
  end

  @doc ~s|Returns an `%Ecto.Changeset{}` for tracking user password changes.\n|
  def change_user_password(%User{} = user, attrs \\ %{}) do
    User.password_changeset(user, attrs)
  end

  @doc ~s|Initiates 2FA setup for a user by generating a secret and backup codes.\n\nReturns the secret and provisioning URI for QR code generation.\n|
  def initiate_two_factor_setup(%User{} = user) do
    secret = TwoFactor.generate_secret()
    {plain_codes, hashed_codes} = TwoFactor.generate_backup_codes()
    provisioning_uri = TwoFactor.generate_provisioning_uri(secret, user.username)

    {:ok,
     %{
       secret: secret,
       plain_backup_codes: plain_codes,
       hashed_backup_codes: hashed_codes,
       provisioning_uri: provisioning_uri
     }}
  rescue
    _ -> {:error, :setup_failed}
  end

  @doc ~s|Enables 2FA for a user after verifying the TOTP code.\nExpects hashed_backup_codes (not plain codes) for storage.\n|
  def enable_two_factor(%User{} = user, secret, hashed_backup_codes, totp_code) do
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
          encoded_secret =
            if is_binary(secret) do
              Base.encode64(secret)
            else
              secret
            end

          changeset =
            User.enable_two_factor_changeset(user, %{
              two_factor_secret: encoded_secret,
              two_factor_backup_codes: hashed_backup_codes
            })

          if changeset.valid? do
            try do
              case Repo.update(changeset) do
                {:ok, updated_user} ->
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
          else
            Logger.error("2FA changeset errors: #{inspect(changeset.errors)}")
            {:error, :invalid_changeset}
          end
        else
          {:error, :invalid_totp_code}
        end

      {:error, reason} ->
        Logger.error("2FA: Database connectivity failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc ~s|Disables 2FA for a user.\n|
  def disable_two_factor(%User{} = user) do
    user |> User.disable_two_factor_changeset() |> Repo.update()
  end

  @doc ~s|Verifies a 2FA code (TOTP or backup code) for a user.\n|
  def verify_two_factor_code(%User{two_factor_enabled: true} = user, code) do
    decoded_secret =
      if is_binary(user.two_factor_secret) do
        case Base.decode64(user.two_factor_secret) do
          {:ok, secret} -> secret
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
            user |> User.update_backup_codes_changeset(remaining_codes) |> Repo.update()
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

  @doc ~s|Verifies a TOTP code ONLY (not backup codes) for a user.\nThis is used for sensitive operations like disabling 2FA where backup codes should not be allowed.\n|
  def verify_totp_only(%User{two_factor_enabled: true} = user, code) do
    decoded_secret =
      if is_binary(user.two_factor_secret) do
        case Base.decode64(user.two_factor_secret) do
          {:ok, secret} -> secret
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

  @doc ~s|Regenerates backup codes for a user with 2FA enabled.\nReturns {:ok, {updated_user, plain_backup_codes}} so user can save them.\n|
  def regenerate_backup_codes(%User{two_factor_enabled: true} = user) do
    {plain_codes, hashed_codes} = TwoFactor.generate_backup_codes()
    result = user |> User.update_backup_codes_changeset(hashed_codes) |> Repo.update()

    case result do
      {:ok, updated_user} -> {:ok, {updated_user, plain_codes}}
      error -> error
    end
  end

  def regenerate_backup_codes(%User{two_factor_enabled: false}) do
    {:error, :two_factor_not_enabled}
  end

  @doc ~s|Admin function to reset a user's 2FA (disable and clear all 2FA data).\n|
  def admin_reset_2fa(user) do
    user |> User.admin_2fa_reset_changeset() |> Repo.update()
  end

  @doc ~s|Lists all app passwords for a user.\n|
  def list_app_passwords(user_id) do
    AppPassword |> where(user_id: ^user_id) |> order_by(desc: :inserted_at) |> Repo.all()
  end

  @doc ~s|Creates a new app password for a user.\nReturns {:ok, app_password} with the raw token attached, or {:error, changeset}.\n|
  def create_app_password(user_id, attrs) do
    attrs = Map.put(attrs, :user_id, user_id)
    changeset = AppPassword.create_changeset(attrs)

    case Repo.insert(changeset) do
      {:ok, app_password} ->
        token = changeset.changes[:token]
        {:ok, %{app_password | token: token}}

      error ->
        error
    end
  end

  @doc ~s|Deletes an app password.\n|
  def delete_app_password(app_password_id, user_id) do
    AppPassword
    |> where(id: ^app_password_id, user_id: ^user_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      app_password -> Repo.delete(app_password)
    end
  end

  @doc ~s|Authenticates a user with an app password.\nReturns:\n  - {:ok, user} if valid\n  - {:error, :user_not_found} if user doesn't exist\n  - {:error, {:invalid_token, user}} if user exists but token is invalid\n|
  def authenticate_with_app_password(username, token) do
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

  @doc ~s|Verifies an app password token for a user.\nUpdates last used timestamp if valid.\n|
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
        {:ok, updated} = app_password |> AppPassword.update_last_used(ip_address) |> Repo.update()
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
            if domain in ["elektrine.com", "z.org"] do
              get_user_by_username_case_insensitive(username)
            else
              get_user_by_mailbox_email(normalized_identifier)
            end

          if user do
            {:ok, user}
          else
            {:error, :not_found}
          end

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

  defp get_user_by_username_case_insensitive(username) when is_binary(username) do
    User
    |> where([u], fragment("lower(?)", u.username) == ^String.downcase(username))
    |> Repo.one()
  end

  @doc ~s|Updates a user's recovery email.\n|
  def update_recovery_email(%User{} = user, attrs) do
    user |> User.recovery_email_changeset(attrs) |> Repo.update()
  end

  @doc ~s|Initiates a password reset by generating a token and sending email.\nReturns {:ok, user} if successful, even if no recovery email is set.\nIf multiple users have the same recovery email, sends reset emails to all of them.\n|
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
        {:ok, :user_not_found}

      users_list ->
        results =
          Enum.map(users_list, fn user ->
            case user do
              %User{is_admin: true} ->
                Logger.error(
                  "SECURITY ALERT: Attempted password reset for admin user: #{user.username}"
                )

                {:ok, :admin_blocked}

              %User{recovery_email: recovery_email, recovery_email_verified: true}
              when not is_nil(recovery_email) ->
                token = generate_password_reset_token()

                case user |> User.password_reset_changeset(token) |> Repo.update() do
                  {:ok, updated_user} ->
                    send_password_reset_email(updated_user, token)
                    {:ok, updated_user}

                  {:error, changeset} ->
                    {:error, changeset}
                end

              %User{recovery_email: recovery_email, recovery_email_verified: verified}
              when not is_nil(recovery_email) and verified != true ->
                {:error, :recovery_email_not_verified}

              %User{} ->
                {:error, :no_recovery_email}
            end
          end)

        if Enum.any?(results, fn
             {:ok, %User{}} -> true
             _ -> false
           end) do
          {:ok, :emails_sent}
        else
          {:ok, :user_not_found}
        end
    end
  end

  @doc ~s|Gets all users by recovery email (returns a list to handle potential duplicates).\n|
  def get_users_by_recovery_email(email) when is_binary(email) do
    from(u in User, where: u.recovery_email == ^email) |> Repo.all()
  end

  @doc ~s|Gets a user by password reset token.\n|
  def get_user_by_password_reset_token(token) when is_binary(token) do
    Repo.get_by(User, password_reset_token: token)
  end

  @doc ~s|Resets a user's password using a valid token.\n|
  def reset_password_with_token(token, attrs) when is_binary(token) do
    case get_user_by_password_reset_token(token) do
      %User{is_admin: true} = user ->
        Logger.error(
          "SECURITY ALERT: Attempted password reset completion for admin user: #{user.username}"
        )

        {:error, :invalid_token}

      %User{} = user ->
        if User.valid_password_reset_token?(user) do
          user |> User.password_reset_with_token_changeset(attrs) |> Repo.update()
        else
          {:error, :invalid_token}
        end

      nil ->
        {:error, :invalid_token}
    end
  end

  @doc ~s|Validates a password reset token without using it.\n|
  def validate_password_reset_token(token) when is_binary(token) do
    case get_user_by_password_reset_token(token) do
      %User{is_admin: true} = user ->
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

  @doc ~s|Clears a password reset token.\n|
  def clear_password_reset_token(%User{} = user) do
    user |> User.clear_password_reset_changeset() |> Repo.update()
  end

  @doc ~s|Returns users whose passwords are older than the specified number of days.\n|
  def get_users_with_old_passwords(max_days) when is_integer(max_days) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-max_days, :day)

    from(u in User,
      where: not is_nil(u.last_password_change) and u.last_password_change < ^cutoff_date,
      select: [:id, :username, :email, :last_password_change, :is_admin],
      order_by: [asc: u.last_password_change]
    )
    |> Repo.all()
  end

  @doc ~s|Returns the count of users whose passwords are older than the specified number of days.\n|
  def count_users_with_old_passwords(max_days) when is_integer(max_days) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-max_days, :day)

    from(u in User,
      where: not is_nil(u.last_password_change) and u.last_password_change < ^cutoff_date
    )
    |> Repo.aggregate(:count)
  end

  @doc ~s|Admin function to reset a user's password with a new temporary password.\n|
  def admin_reset_password(user, attrs) do
    user |> User.admin_password_reset_changeset(attrs) |> Repo.update()
  end

  defp generate_password_reset_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp send_password_reset_email(%User{recovery_email: recovery_email} = user, token)
       when not is_nil(recovery_email) do
    Elektrine.UserNotifier.password_reset_instructions(user, token) |> Elektrine.Mailer.deliver()
  rescue
    e ->
      Logger.error("Failed to send password reset email: #{inspect(e)}")
      {:error, :email_failed}
  end

  defp send_password_reset_email(_, _) do
    {:error, :no_recovery_email}
  end
end
