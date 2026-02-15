defmodule ElektrineWeb.API.SettingsController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Profiles
  alias Elektrine.Repo

  action_fallback ElektrineWeb.FallbackController

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
        notify_on_email_received: user.notify_on_email_received,
        notify_on_mention: user.notify_on_mention,
        notify_on_reply: user.notify_on_reply,
        notify_on_new_follower: user.notify_on_new_follower,
        notify_on_direct_message: user.notify_on_direct_message
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
      |> Map.take(["display_name", "locale", "timezone"])
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

    # Build notification attrs from params
    attrs =
      params
      |> Map.take([
        "notify_on_email_received",
        "notify_on_mention",
        "notify_on_reply",
        "notify_on_follow",
        "notify_on_message"
      ])
      |> Enum.into(%{})

    case Accounts.update_user(user, attrs) do
      {:ok, _updated_user} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Notification settings updated successfully"})

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

  @doc """
  PUT /api/settings/password
  Changes user password
  """
  def update_password(conn, %{
        "current_password" => current_password,
        "new_password" => new_password
      }) do
    user = conn.assigns[:current_user]

    # Update password using User changeset (includes current_password validation)
    changeset =
      User.password_changeset(user, %{
        current_password: current_password,
        password: new_password,
        password_confirmation: new_password
      })

    case Repo.update(changeset) do
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

  def update_password(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "current_password and new_password are required"})
  end
end
