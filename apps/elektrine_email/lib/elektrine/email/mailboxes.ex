defmodule Elektrine.Email.Mailboxes do
  @moduledoc """
  Mailbox management context.
  Handles mailbox creation, retrieval, updates, and ownership operations.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Ecto.Multi
  alias Elektrine.Email.{Mailbox, Message}
  alias Elektrine.Repo

  @doc """
  Gets a user's mailbox.
  Returns nil if the Mailbox does not exist.
  """
  def get_user_mailbox(user_id) do
    Mailbox
    |> where(user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Gets all mailboxes for a user (both elektrine.com and z.org).
  Returns a list of mailboxes.
  """
  def get_user_mailboxes(user_id) do
    Mailbox
    |> where(user_id: ^user_id)
    |> order_by(:email)
    |> Repo.all()
  end

  @doc """
  Gets a single mailbox for admin operations (bypasses ownership checks).

  WARNING: Only use this for admin operations where access control is handled
  at the plug/authorization layer. For regular user operations, use get_mailbox(id, user_id).
  """
  def get_mailbox_admin(id), do: Repo.get(Mailbox, id)

  @doc """
  Gets a single mailbox for internal system operations (bypasses ownership checks).

  WARNING: Only use this for internal background jobs and system operations that
  don't involve user requests. For user-facing operations, use get_mailbox(id, user_id).

  Examples: cache operations, email sending jobs, system adapters.
  """
  def get_mailbox_internal(id), do: Repo.get(Mailbox, id)

  @doc """
  Gets a mailbox by email address.
  """
  def get_mailbox_by_email(email) when is_binary(email) do
    # First try direct email lookup for backwards compatibility
    case Mailbox |> where(email: ^email) |> Repo.one() do
      %Mailbox{} = mailbox ->
        mailbox

      nil ->
        # Try username-based lookup for domain-agnostic approach
        case String.split(email, "@") do
          [username, domain] when domain in ["elektrine.com", "z.org"] ->
            # Support plus addressing (e.g., username+tag@domain.com -> username@domain.com)
            base_username = username |> String.split("+") |> List.first()
            get_mailbox_by_username(base_username)

          _ ->
            nil
        end
    end
  end

  @doc """
  Gets a mailbox by username (domain-agnostic).
  """
  def get_mailbox_by_username(username) when is_binary(username) do
    Mailbox
    |> where(username: ^username)
    |> Repo.one()
  end

  @doc """
  Gets a single mailbox for a specific user.
  Returns nil if the Mailbox does not exist for that user.
  """
  def get_mailbox(id, user_id) do
    Mailbox
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Creates a mailbox for a user or with the given parameters.
  """
  def create_mailbox(user) when is_struct(user) do
    Mailbox.create_for_user(user)
    |> Repo.insert()
  end

  def create_mailbox(mailbox_params) when is_map(mailbox_params) do
    %Mailbox{}
    |> Mailbox.changeset(mailbox_params)
    |> Repo.insert()
  end

  @doc """
  Ensures a user has a mailbox, creating one if it doesn't exist.
  Also fixes email address if it doesn't match the current username.
  """
  def ensure_user_has_mailbox(user) do
    case get_user_mailbox(user.id) do
      nil ->
        create_mailbox(user)

      mailbox ->
        # Check if mailbox email matches current username
        domain = Application.get_env(:elektrine, :email)[:domain] || "elektrine.com"
        expected_email = "#{user.username}@#{domain}"

        if mailbox.email != expected_email do
          Logger.warning(
            "Mailbox email mismatch for user #{user.id}: #{mailbox.email} vs expected #{expected_email}"
          )

          # Check if expected email is available before updating
          case get_mailbox_by_email(expected_email) do
            nil ->
              # Expected email is available, safe to update
              case update_mailbox_email(mailbox, expected_email) do
                {:ok, updated_mailbox} ->
                  Logger.info(
                    "Fixed mailbox email for user #{user.id}: #{mailbox.email} -> #{expected_email}"
                  )

                  {:ok, updated_mailbox}

                {:error, reason} ->
                  Logger.warning(
                    "Could not update mailbox email for user #{user.id}: #{inspect(reason)}"
                  )

                  {:ok, mailbox}
              end

            existing_mailbox ->
              # Expected email is taken by another user
              Logger.warning(
                "Cannot fix mailbox email for user #{user.id} - #{expected_email} is taken by mailbox #{existing_mailbox.id}"
              )

              # Return existing mailbox - user keeps their current email
              {:ok, mailbox}
          end
        else
          {:ok, mailbox}
        end
    end
  end

  @doc """
  Returns the list of mailboxes for a user.
  """
  def list_mailboxes(user_id) do
    Mailbox
    |> where(user_id: ^user_id)
    |> order_by([m], asc: m.email)
    |> Repo.all()
  end

  @doc """
  Returns all mailboxes in the system.
  """
  def list_all_mailboxes do
    Mailbox
    |> order_by([m], asc: m.id)
    |> Repo.all()
  end

  @doc """
  Updates a mailbox.
  """
  def update_mailbox(mailbox, attrs) do
    mailbox
    |> Mailbox.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a mailbox email address (used when username changes).
  """
  def update_mailbox_email(mailbox, new_email) do
    # Check if the new email is already taken by another mailbox
    case get_mailbox_by_email(new_email) do
      nil ->
        # Email is available, update it
        update_mailbox(mailbox, %{email: new_email})

      existing_mailbox when existing_mailbox.id == mailbox.id ->
        # Same mailbox, no change needed
        {:ok, mailbox}

      _other_mailbox ->
        # Email is taken by another mailbox
        {:error, "Email address already in use by another mailbox"}
    end
  end

  @doc """
  Transitions a user's mailbox for username change.
  Creates new clean mailbox, clears old one for future reuse.
  """
  def transition_mailbox_for_username_change(user, old_mailbox, new_email) do
    # Use a transaction to ensure atomicity
    multi =
      Multi.new()
      # Step 1: Create new clean mailbox for user
      |> Multi.insert(:new_mailbox, %Mailbox{email: new_email, user_id: user.id})
      # Step 2: Clear old mailbox user association and data
      |> Multi.update(
        :clear_old_mailbox,
        Mailbox.changeset(old_mailbox, %{
          # Unassign from user
          user_id: nil,
          forward_to: nil,
          forward_enabled: false
        })
      )
      # Step 3: Delete all messages from old mailbox
      |> Multi.delete_all(
        :delete_old_messages,
        from(m in Message, where: m.mailbox_id == ^old_mailbox.id)
      )

    case Repo.transaction(multi) do
      {:ok, %{new_mailbox: new_mailbox}} ->
        Logger.info(
          "Successfully transitioned mailbox for user #{user.id}: old mailbox #{old_mailbox.id} cleared, new mailbox #{new_mailbox.id} created"
        )

        {:ok, new_mailbox}

      {:error, step, changeset, _changes} ->
        Logger.error(
          "Failed to transition mailbox for user #{user.id} at step #{step}: #{Kernel.inspect(changeset)}"
        )

        {:error, "Failed to transition mailbox"}
    end
  end

  @doc """
  Deletes a mailbox.
  """
  def delete_mailbox(mailbox) do
    Repo.delete(mailbox)
  end

  @doc """
  Updates mailbox forwarding settings.
  """
  def update_mailbox_forwarding(%Mailbox{} = mailbox, attrs) do
    mailbox
    |> Mailbox.forwarding_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking mailbox forwarding changes.
  """
  def change_mailbox_forwarding(%Mailbox{} = mailbox, attrs \\ %{}) do
    Mailbox.forwarding_changeset(mailbox, attrs)
  end

  @doc """
  Checks if a mailbox has forwarding enabled and returns the target email.
  Returns nil if forwarding is disabled or not configured.
  """
  def get_mailbox_forward_target(%Mailbox{forward_enabled: true, forward_to: target})
      when is_binary(target) do
    target
  end

  def get_mailbox_forward_target(_mailbox), do: nil

  # Private function - Gets a single mailbox without ownership checks.
  # Use get_mailbox(id, user_id) for user-facing operations,
  # get_mailbox_admin(id) for admin operations, or
  # get_mailbox_internal(id) for internal system operations.
  def get_mailbox(id), do: Repo.get(Mailbox, id)
end
