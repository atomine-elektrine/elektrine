defmodule ElektrineWeb.API.SettingsController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Authentication
  alias Elektrine.Accounts.ClientAppSettings
  alias Elektrine.Accounts.RecoveryEmailVerification
  alias Elektrine.Bluesky.Managed, as: BlueskyManaged
  alias Elektrine.Profiles
  alias Elektrine.Repo

  action_fallback ElektrineWeb.FallbackController

  @notification_setting_fields [
    "notify_on_email_received",
    "notify_on_mention",
    "notify_on_reply",
    "notify_on_new_follower",
    "notify_on_direct_message",
    "notify_on_like",
    "notify_on_discussion_reply",
    "notify_on_comment",
    "block_notifications_from_strangers",
    "hide_notification_contents"
  ]

  @notification_setting_aliases %{
    "block_from_strangers" => "block_notifications_from_strangers",
    "notify_on_follow" => "notify_on_new_follower",
    "notify_on_follower" => "notify_on_new_follower",
    "notify_on_followers" => "notify_on_new_follower",
    "notify_on_message" => "notify_on_direct_message",
    "notify_on_messages" => "notify_on_direct_message",
    "notify_on_direct_messages" => "notify_on_direct_message"
  }

  @doc """
  GET /api/settings
  Returns current user's settings and profile information
  """
  def index(conn, _params) do
    user = conn.assigns[:current_user]

    # Reload user with profile association to get bio
    user = Accounts.get_user!(user.id) |> Repo.preload(:profile)

    # Get bio from profile if it exists (stored as description in UserProfile)
    bio = if user.profile, do: user.profile.description, else: nil

    # Construct avatar URL if avatar exists
    avatar_url =
      if user.avatar do
        "/uploads/avatars/#{user.avatar}"
      else
        nil
      end

    conn
    |> put_status(:ok)
    |> json(%{
      settings: %{
        id: user.id,
        username: user.username,
        handle: user.handle,
        display_name: user.display_name,
        bio: bio,
        avatar_url: avatar_url,
        locale: user.locale || "en",
        timezone: user.timezone || "UTC",
        preferred_email_domain: user.preferred_email_domain,
        available_email_domains: Elektrine.Domains.available_email_domains_for_user(user),
        notify_on_email_received: user.notify_on_email_received,
        notify_on_mention: user.notify_on_mention,
        notify_on_reply: user.notify_on_reply,
        notify_on_new_follower: user.notify_on_new_follower,
        notify_on_direct_message: user.notify_on_direct_message,
        block_notifications_from_strangers: user.block_notifications_from_strangers,
        hide_notification_contents: user.hide_notification_contents,
        bluesky_enabled: user.bluesky_enabled,
        bluesky_identifier: user.bluesky_identifier,
        bluesky_pds_url: user.bluesky_pds_url
      }
    })
  end

  @doc """
  PUT /api/settings/profile
  Updates user profile information
  Note: Username cannot be changed via API
  """
  def update_profile(conn, params) do
    user = conn.assigns[:current_user]

    # Build update attrs from params (only User fields, excluding username)
    user_attrs =
      params
      |> Map.take([
        "display_name",
        "locale",
        "timezone",
        "preferred_email_domain",
        "bluesky_enabled",
        "bluesky_identifier",
        "bluesky_app_password",
        "bluesky_pds_url"
      ])
      # Explicitly prevent username/handle changes
      |> Map.drop(["username", "handle"])
      |> Enum.into(%{})

    # Update user fields
    case Accounts.update_user(user, user_attrs) do
      {:ok, updated_user} ->
        # Update profile bio if provided (stored as description in UserProfile)
        if Map.has_key?(params, "bio") do
          user_with_profile = Repo.preload(updated_user, :profile)

          if user_with_profile.profile do
            Profiles.update_user_profile(user_with_profile.profile, %{description: params["bio"]})
          else
            # Create profile if it doesn't exist
            Profiles.create_user_profile(updated_user.id, %{description: params["bio"]})
          end
        end

        # Reload to get updated data
        updated_user = Accounts.get_user!(updated_user.id) |> Repo.preload(:profile)
        bio = if updated_user.profile, do: updated_user.profile.description, else: nil

        avatar_url =
          if updated_user.avatar do
            "/uploads/avatars/#{updated_user.avatar}"
          else
            nil
          end

        conn
        |> put_status(:ok)
        |> json(%{
          message: "Profile updated successfully",
          user: %{
            username: updated_user.username,
            handle: updated_user.handle,
            display_name: updated_user.display_name,
            bio: bio,
            avatar_url: avatar_url
          }
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to update profile", errors: errors})
    end
  end

  @doc """
  PUT /api/settings/notifications
  Updates notification preferences
  """
  def update_notifications(conn, params) do
    user = conn.assigns[:current_user]

    attrs = notification_attrs(params)

    case Accounts.update_user(user, attrs) do
      {:ok, updated_user} ->
        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          message: "Notification settings updated successfully",
          settings: notification_settings_payload(updated_user)
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to update notifications", errors: errors})
    end
  end

  defp notification_attrs(params) do
    Enum.reduce(params, %{}, fn {key, value}, attrs ->
      canonical_key =
        key
        |> to_string()
        |> then(&Map.get(@notification_setting_aliases, &1, &1))

      if canonical_key in @notification_setting_fields do
        Map.put(attrs, canonical_key, value)
      else
        attrs
      end
    end)
  end

  defp notification_settings_payload(user) do
    %{
      notify_on_email_received: user.notify_on_email_received,
      notify_on_mention: user.notify_on_mention,
      notify_on_reply: user.notify_on_reply,
      notify_on_new_follower: user.notify_on_new_follower,
      notify_on_direct_message: user.notify_on_direct_message,
      notify_on_like: user.notify_on_like,
      notify_on_discussion_reply: user.notify_on_discussion_reply,
      notify_on_comment: user.notify_on_comment,
      block_notifications_from_strangers: user.block_notifications_from_strangers,
      block_from_strangers: user.block_notifications_from_strangers,
      hide_notification_contents: user.hide_notification_contents
    }
  end

  def show_app(conn, %{"app" => app}) do
    user = conn.assigns[:current_user]

    conn
    |> put_status(:ok)
    |> json(ClientAppSettings.get_settings(user.id, app))
  end

  def update_app(conn, %{"app" => app} = params) do
    user = conn.assigns[:current_user]
    patch = Map.drop(params, ["app"])

    case ClientAppSettings.update_settings(user.id, app, patch) do
      {:ok, settings} ->
        conn
        |> put_status(:ok)
        |> json(settings)

      {:error, :invalid_settings} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "settings must be an object"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_app_settings", details: changeset_errors(changeset)})
    end
  end

  @doc """
  PUT /api/settings/password
  Changes user password
  """
  def update_password(conn, %{
        "current_password" => current_password,
        "new_password" => new_password
      }) do
    update_password_with_confirmation(conn, current_password, new_password, new_password)
  end

  def update_password(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "current_password and new_password are required"})
  end

  def change_password(
        conn,
        %{
          "password" => current_password,
          "new_password" => new_password
        } = params
      ) do
    new_password_confirmation = Map.get(params, "new_password_confirmation", new_password)

    update_password_with_confirmation(
      conn,
      current_password,
      new_password,
      new_password_confirmation
    )
  end

  def change_password(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "password and new_password are required"})
  end

  def change_email(conn, %{"password" => password, "email" => email}) do
    user = conn.assigns[:current_user]

    with {:ok, _user} <- Authentication.verify_user_password(user, password),
         {:ok, updated_user} <- RecoveryEmailVerification.set_recovery_email(user.id, email) do
      conn
      |> put_status(:ok)
      |> json(%{
        status: "success",
        email: updated_user.recovery_email,
        verified: updated_user.recovery_email_verified
      })
    else
      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Password is incorrect"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to update email", errors: changeset_errors(changeset)})

      {:error, :user_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})
    end
  end

  def change_email(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "password and email are required"})
  end

  defp update_password_with_confirmation(
         conn,
         current_password,
         new_password,
         new_password_confirmation
       ) do
    user = conn.assigns[:current_user]

    case Authentication.update_user_password(user, %{
           current_password: current_password,
           password: new_password,
           password_confirmation: new_password_confirmation
         }) do
      {:ok, _updated_user} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Password updated successfully"})

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        # Check if error is due to incorrect current password
        if Map.has_key?(errors, :current_password) do
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "Current password is incorrect"})
        else
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to update password", errors: errors})
        end
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @doc """
  POST /api/settings/bluesky/enable
  Connects Bluesky by provisioning an account automatically.
  """
  def enable_bluesky_managed(conn, %{"current_password" => current_password}) do
    user = conn.assigns[:current_user]

    case BlueskyManaged.enable_for_user(user, current_password) do
      {:ok, %{user: updated_user, did: did, handle: handle}} ->
        conn
        |> put_status(:ok)
        |> json(%{
          message: "Bluesky enabled successfully",
          bluesky: %{
            enabled: updated_user.bluesky_enabled,
            did: did,
            handle: handle,
            identifier: updated_user.bluesky_identifier,
            pds_url: updated_user.bluesky_pds_url
          }
        })

      {:error, :managed_pds_disabled} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Bluesky provisioning is disabled"})

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Current password is incorrect"})

      {:error, :already_enabled} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Bluesky is already enabled for this account"})

      {:error, :current_password_required} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "current_password is required"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to enable Bluesky", errors: changeset_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to enable Bluesky", reason: inspect(reason)})
    end
  end

  def enable_bluesky_managed(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "current_password is required"})
  end
end
