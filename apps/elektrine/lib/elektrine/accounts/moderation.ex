defmodule Elektrine.Accounts.Moderation do
  @moduledoc """
  User moderation functionality for administrators.
  Handles banning, suspending, and administrative operations on user accounts.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.{AccountDeletionRequest, User}
  alias Elektrine.Repo

  require Logger

  ## Ban/Suspend Operations

  @doc """
  Bans a user with an optional reason.
  Admins cannot be banned for security reasons.

  ## Examples

      iex> ban_user(user, %{banned_reason: "Violation of terms"})
      {:ok, %User{}}

      iex> ban_user(admin_user)
      {:error, :cannot_ban_admin}

  """
  def ban_user(%User{} = user, attrs \\ %{}) do
    if user.is_admin do
      {:error, :cannot_ban_admin}
    else
      user
      |> User.ban_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Unbans a user.

  ## Examples

      iex> unban_user(user)
      {:ok, %User{}}

  """
  def unban_user(%User{} = user) do
    user
    |> User.unban_changeset()
    |> Repo.update()
  end

  @doc """
  Suspends a user until a specific date/time.
  Admins cannot be suspended for security reasons.

  ## Examples

      iex> suspend_user(user, %{suspended_until: ~U[2024-12-31 23:59:59Z], suspension_reason: "Spam"})
      {:ok, %User{}}

      iex> suspend_user(admin_user, %{suspended_until: ~U[2024-12-31 23:59:59Z]})
      {:error, :cannot_suspend_admin}

  """
  def suspend_user(%User{} = user, attrs) do
    if user.is_admin do
      {:error, :cannot_suspend_admin}
    else
      user
      |> User.suspend_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Unsuspends a user.

  ## Examples

      iex> unsuspend_user(user)
      {:ok, %User{}}

  """
  def unsuspend_user(%User{} = user) do
    user
    |> User.unsuspend_changeset()
    |> Repo.update()
  end

  @doc """
  Checks if a user is currently suspended.
  """
  def user_suspended?(%User{} = user) do
    user.suspended &&
      (is_nil(user.suspended_until) ||
         DateTime.compare(user.suspended_until, DateTime.utc_now()) == :gt)
  end

  @doc """
  Automatically unsuspends users whose suspension period has expired.
  """
  def unsuspend_expired_users do
    now = DateTime.utc_now()

    from(u in User,
      where: u.suspended == true,
      where: not is_nil(u.suspended_until),
      where: u.suspended_until <= ^now
    )
    |> Repo.all()
    |> Enum.each(&unsuspend_user/1)
  end

  ## Admin User Management

  @doc """
  Updates a user's admin status.

  ## Examples

      iex> update_user_admin_status(user, true)
      {:ok, %User{}}

      iex> update_user_admin_status(user, false)
      {:ok, %User{}}

  """
  def update_user_admin_status(%User{} = user, is_admin) when is_boolean(is_admin) do
    user
    |> Ecto.Changeset.cast(%{is_admin: is_admin}, [:is_admin])
    |> Repo.update()
  end

  @doc """
  Creates a user (admin only).

  ## Examples

      iex> admin_create_user(%{username: "newuser", password: "password123", password_confirmation: "password123"})
      {:ok, %User{}}

      iex> admin_create_user(%{username: ""})
      {:error, %Ecto.Changeset{}}

  """
  def admin_create_user(attrs \\ %{}) do
    result =
      %User{}
      |> User.admin_registration_changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, user} ->
        # Create a mailbox for the user
        Elektrine.Email.create_mailbox(user)
        {:ok, user}

      error ->
        error
    end
  end

  @doc """
  Updates a user (admin only).

  ## Examples

      iex> admin_update_user(user, %{username: "new_username"})
      {:ok, %User{}}

      iex> admin_update_user(user, %{username: ""})
      {:error, %Ecto.Changeset{}}

  """
  def admin_update_user(%User{} = user, attrs) do
    changeset = User.admin_changeset(user, attrs)

    case Repo.update(changeset) do
      {:ok, updated_user} ->
        # Update mailbox email if username changed
        case Ecto.Changeset.get_change(changeset, :username) do
          nil ->
            # Username didn't change
            {:ok, updated_user}

          _new_username ->
            # Username changed, update mailbox email
            update_mailbox_email_for_username_change(updated_user)
            {:ok, updated_user}
        end

      error ->
        error
    end
  end

  @doc """
  Deletes a user and all associated data (admin operation).

  ## Examples

      iex> admin_delete_user(user)
      {:ok, %User{}}

      iex> admin_delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def admin_delete_user(%User{} = user) do
    # Delete all user's data first
    Repo.transaction(fn ->
      # Delete user's messages through their mailboxes
      from(m in Elektrine.Email.Message,
        join: mb in Elektrine.Email.Mailbox,
        on: m.mailbox_id == mb.id,
        where: mb.user_id == ^user.id
      )
      |> Repo.delete_all()

      # Delete user's mailboxes
      from(mb in Elektrine.Email.Mailbox, where: mb.user_id == ^user.id)
      |> Repo.delete_all()

      # Delete user's email aliases
      from(a in Elektrine.Email.Alias, where: a.user_id == ^user.id)
      |> Repo.delete_all()

      # Finally delete the user
      case Repo.delete(user) do
        {:ok, user} -> user
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user admin changes.

  ## Examples

      iex> change_user_admin(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_admin(%User{} = user, attrs \\ %{}) do
    User.admin_changeset(user, attrs)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for creating a user (admin only).

  ## Examples

      iex> change_user_admin_registration(%User{})
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_admin_registration(%User{} = user, attrs \\ %{}) do
    User.admin_registration_changeset(user, attrs)
  end

  ## Account Deletion Request Management

  @doc """
  Creates an account deletion request.

  ## Examples

      iex> create_deletion_request(user, %{reason: "No longer needed"})
      {:ok, %AccountDeletionRequest{}}

      iex> create_deletion_request(user, %{})
      {:error, %Ecto.Changeset{}}

  """
  def create_deletion_request(%User{} = user, attrs \\ %{}) do
    attrs = Map.put(attrs, :user_id, user.id)
    attrs = Map.put(attrs, :requested_at, DateTime.utc_now() |> DateTime.truncate(:second))

    %AccountDeletionRequest{}
    |> AccountDeletionRequest.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a user's pending deletion request.

  ## Examples

      iex> get_pending_deletion_request(user)
      %AccountDeletionRequest{}

      iex> get_pending_deletion_request(user)
      nil

  """
  def get_pending_deletion_request(%User{} = user) do
    Repo.get_by(AccountDeletionRequest, user_id: user.id, status: "pending")
  end

  @doc """
  Lists all account deletion requests.

  ## Examples

      iex> list_deletion_requests()
      [%AccountDeletionRequest{}, ...]

  """
  def list_deletion_requests do
    from(r in AccountDeletionRequest,
      join: u in User,
      on: r.user_id == u.id,
      left_join: admin in User,
      on: r.reviewed_by_id == admin.id,
      select: %{r | user: u, reviewed_by: admin},
      order_by: [desc: r.requested_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single deletion request.

  ## Examples

      iex> get_deletion_request!(123)
      %AccountDeletionRequest{}

      iex> get_deletion_request!(456)
      ** (Ecto.NoResultsError)

  """
  def get_deletion_request!(id) do
    from(r in AccountDeletionRequest,
      join: u in User,
      on: r.user_id == u.id,
      left_join: admin in User,
      on: r.reviewed_by_id == admin.id,
      where: r.id == ^id,
      select: %{r | user: u, reviewed_by: admin}
    )
    |> Repo.one!()
  end

  @doc """
  Reviews an account deletion request (approve or deny).

  ## Examples

      iex> review_deletion_request(request, admin, "approved", %{admin_notes: "Approved"})
      {:ok, %AccountDeletionRequest{}}

      iex> review_deletion_request(request, admin, "denied", %{admin_notes: "Invalid reason"})
      {:ok, %AccountDeletionRequest{}}

  """
  def review_deletion_request(
        %AccountDeletionRequest{} = request,
        %User{} = admin,
        status,
        attrs \\ %{}
      ) do
    review_attrs = %{
      status: status,
      reviewed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      reviewed_by_id: admin.id,
      admin_notes: Map.get(attrs, :admin_notes)
    }

    result =
      request
      |> AccountDeletionRequest.review_changeset(review_attrs)
      |> Repo.update()

    case result do
      {:ok, updated_request} when status == "approved" ->
        # If approved, delete the user account
        user = Repo.get!(User, request.user_id)

        case admin_delete_user(user) do
          {:ok, _user} -> {:ok, updated_request}
          {:error, _changeset} -> {:error, "Failed to delete user account"}
        end

      {:ok, updated_request} ->
        {:ok, updated_request}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Updates the user's mailbox email address to match their new username.
  # This prevents duplicate mailboxes when usernames change.
  defp update_mailbox_email_for_username_change(user) do
    case Elektrine.Email.get_user_mailbox(user.id) do
      nil ->
        :ok

      mailbox ->
        # Calculate the new email address based on current username
        domain = Application.get_env(:elektrine, :email)[:domain] || "elektrine.com"
        new_email = "#{user.username}@#{domain}"

        # Only process if the email is different
        if mailbox.email != new_email do
          # Check if the new email conflicts with an existing mailbox
          case Elektrine.Email.get_mailbox_by_email(new_email) do
            nil ->
              # New email is available - transition the mailbox
              case Elektrine.Email.transition_mailbox_for_username_change(
                     user,
                     mailbox,
                     new_email
                   ) do
                {:ok, _new_mailbox} ->
                  :ok

                {:error, reason} ->
                  Logger.error(
                    "Failed to transition mailbox for user #{user.id}: #{inspect(reason)}"
                  )

                  :ok
              end

            _existing_mailbox ->
              # Conflict! The new username's email is already taken
              Logger.error("Cannot create #{new_email} for user #{user.id} - email already taken")
              :ok
          end
        else
          :ok
        end
    end
  end
end
