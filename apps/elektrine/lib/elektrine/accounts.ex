defmodule Elektrine.Accounts do
  @moduledoc """
  The Accounts context.
  Handles user accounts, authentication, and related functionality.

  This module serves as the main entry point for account-related operations
  and delegates to specialized sub-contexts for specific functionality:

  - `Elektrine.Accounts.Authentication` - Password and 2FA authentication
  - `Elektrine.Accounts.Blocking` - User blocking functionality
  - `Elektrine.Accounts.Muting` - User muting functionality
  - `Elektrine.Accounts.Moderation` - Admin moderation operations
  - `Elektrine.Accounts.MultiAccount` - Multi-account detection
  - `Elektrine.Accounts.Tracking` - User activity tracking
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo

  alias Elektrine.Accounts.InviteCode
  alias Elektrine.Accounts.InviteCodeUse
  alias Elektrine.Accounts.User
  alias Elektrine.Accounts.UsernameHistory
  alias Elektrine.Async
  alias Elektrine.Platform.Modules

  # Import sub-context modules for delegation
  alias Elektrine.Accounts.Authentication
  alias Elektrine.Accounts.Blocking
  alias Elektrine.Accounts.Moderation
  alias Elektrine.Accounts.MultiAccount
  alias Elektrine.Accounts.Muting
  alias Elektrine.Accounts.Tracking

  require Logger

  @self_service_invite_active_limit 5
  @self_service_invite_monthly_generation_limit 5
  @self_service_invite_monthly_use_limit 5
  @self_service_invite_max_uses 1
  @self_service_invite_expiry_days 14
  @seconds_per_day 86_400
  @activitypub_actor_update_fields [:avatar]

  ## Core User Management

  @doc """
  Returns the list of users.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
    from(u in User,
      order_by: [desc: u.inserted_at],
      select: [
        :id,
        :username,
        :is_admin,
        :banned,
        :inserted_at,
        :registration_ip,
        :last_login_ip,
        :last_login_at,
        :login_count
      ]
    )
    |> Repo.all()
  end

  @doc """
  Searches for users by username or display name, excluding the current user.
  """
  def search_users(query, current_user_id) do
    # Sanitize search term to prevent LIKE pattern injection
    safe_query = sanitize_search_term(query)
    query_term = "%#{String.downcase(safe_query)}%"

    from(u in User,
      where: u.id != ^current_user_id,
      where:
        fragment("LOWER(?) LIKE ?", u.username, ^query_term) or
          fragment("LOWER(?) LIKE ?", u.display_name, ^query_term) or
          fragment("LOWER(?) LIKE ?", u.handle, ^query_term),
      order_by: [asc: u.username],
      limit: 10,
      select: [:id, :username, :display_name, :avatar, :handle]
    )
    |> Repo.all()
  end

  # Sanitize search terms to prevent LIKE pattern injection
  defp sanitize_search_term(term), do: Elektrine.TextHelpers.sanitize_search_term(term)

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a user by username.

  Returns nil if the User does not exist.

  ## Examples

      iex> get_user_by_username("username")
      %User{}

      iex> get_user_by_username("nonexistent")
      nil

  """
  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  @doc """
  Gets a user by username or handle (case-insensitive for handle).
  Useful for @mentions where users might use either.
  """
  def get_user_by_username_or_handle(identifier) when is_binary(identifier) do
    # Try username first (exact match)
    case Repo.get_by(User, username: identifier) do
      nil ->
        # Try handle (case-insensitive)
        Repo.one(
          from u in User, where: fragment("lower(?)", u.handle) == ^String.downcase(identifier)
        )

      user ->
        user
    end
  end

  @doc """
  Creates a user.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(attrs \\ %{}) do
    result =
      %User{}
      |> User.registration_changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, user} ->
        maybe_create_user_mailbox(user)

        # Keys will be generated lazily when first needed for federation

        # Reload user to get database default values (onboarding_completed, etc.)
        user = Repo.get!(User, user.id)

        {:ok, user}

      error ->
        error
    end
  end

  @doc """
  Updates a user.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs) do
    changeset = User.changeset(user, attrs)

    case Repo.update(changeset) do
      {:ok, updated_user} ->
        # Record username history and update mailbox if username changed
        case Ecto.Changeset.get_change(changeset, :username) do
          nil ->
            :ok

          new_username ->
            record_username_change(user.id, user.username, new_username)
            update_mailbox_email_for_username_change(updated_user)
        end

        maybe_federate_actor_update(updated_user, changeset)
        {:ok, updated_user}

      error ->
        error
    end
  end

  defp maybe_federate_actor_update(%User{activitypub_enabled: true} = user, changeset) do
    if actor_update_field_changed?(changeset) do
      Async.run(fn ->
        Elektrine.ActivityPub.Outbox.federate_profile_update(user.id)
      end)
    end

    :ok
  end

  defp maybe_federate_actor_update(_user, _changeset), do: :ok

  defp actor_update_field_changed?(%Ecto.Changeset{changes: changes}) do
    Enum.any?(@activitypub_actor_update_fields, &Map.has_key?(changes, &1))
  end

  @doc """
  Updates the addressbook sync token (ctag) for a user.
  Used by CardDAV for sync detection.
  """
  def update_addressbook_ctag(%User{} = user, ctag) do
    user
    |> Ecto.Changeset.change(%{addressbook_ctag: ctag})
    |> Repo.update()
  end

  @doc """
  Deletes a user and all associated data.

  ## Examples

      iex> delete_user(user)
      {:ok, %User{}}

      iex> delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user(%User{} = user) do
    # Delete all user's data first
    Repo.transaction(fn ->
      maybe_delete_email_data(user)

      # Finally delete the user
      case Repo.delete(user) do
        {:ok, user} -> user
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user registration changes.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  @doc """
  Get user's sequential number based on account creation order.
  Returns the position of this user in the chronological list of all users.
  """
  def get_user_number(user) do
    from(u in User,
      where: u.inserted_at <= ^user.inserted_at,
      select: count(u.id)
    )
    |> Repo.one()
  end

  @doc """
  Updates a user's locale and/or timezone preference.
  """
  def update_user_locale(%User{} = user, attrs) when is_map(attrs) do
    user
    |> User.locale_changeset(attrs)
    |> Repo.update()
  end

  def update_user_locale(%User{} = user, locale) when is_binary(locale) do
    update_user_locale(user, %{locale: locale})
  end

  ## Authentication Functions - Delegated to Authentication module

  defdelegate authenticate_user(username, password), to: Authentication
  defdelegate verify_user_password(user, password), to: Authentication
  defdelegate update_user_password(user, attrs, opts \\ []), to: Authentication
  defdelegate change_user_password(user, attrs \\ %{}), to: Authentication

  # Two-Factor Authentication
  defdelegate initiate_two_factor_setup(user), to: Authentication
  defdelegate enable_two_factor(user, secret, backup_codes, totp_code), to: Authentication
  defdelegate disable_two_factor(user), to: Authentication
  defdelegate verify_two_factor_code(user, code), to: Authentication
  defdelegate verify_totp_only(user, code), to: Authentication
  defdelegate regenerate_backup_codes(user), to: Authentication
  defdelegate admin_reset_2fa(user), to: Authentication

  # App Passwords
  defdelegate list_app_passwords(user_id), to: Authentication
  defdelegate create_app_password(user_id, attrs), to: Authentication
  defdelegate delete_app_password(app_password_id, user_id), to: Authentication
  defdelegate authenticate_with_app_password(username, token), to: Authentication
  defdelegate verify_app_password(user_id, token, ip_address \\ nil), to: Authentication

  # Password Recovery
  defdelegate update_recovery_email(user, attrs), to: Authentication
  defdelegate initiate_password_reset(username_or_email), to: Authentication
  defdelegate get_users_by_recovery_email(email), to: Authentication
  defdelegate get_user_by_password_reset_token(token), to: Authentication
  defdelegate reset_password_with_token(token, attrs), to: Authentication
  defdelegate validate_password_reset_token(token), to: Authentication
  defdelegate clear_password_reset_token(user), to: Authentication
  defdelegate get_users_with_old_passwords(max_days), to: Authentication
  defdelegate count_users_with_old_passwords(max_days), to: Authentication
  defdelegate admin_reset_password(user, attrs), to: Authentication

  ## Blocking Functions - Delegated to Blocking module

  defdelegate block_user(blocker_id, blocked_id, reason \\ nil), to: Blocking
  defdelegate unblock_user(blocker_id, blocked_id), to: Blocking
  defdelegate user_blocked?(blocker_id, blocked_id), to: Blocking
  defdelegate list_blocked_users(blocker_id), to: Blocking
  defdelegate list_users_who_blocked(blocked_id), to: Blocking

  ## Muting Functions - Delegated to Muting module

  defdelegate mute_user(muter_id, muted_id, mute_notifications \\ false), to: Muting
  defdelegate unmute_user(muter_id, muted_id), to: Muting
  defdelegate user_muted?(muter_id, muted_id), to: Muting
  defdelegate user_muting_notifications?(muter_id, muted_id), to: Muting
  defdelegate list_muted_users(muter_id), to: Muting

  ## Moderation Functions - Delegated to Moderation module

  defdelegate ban_user(user, attrs \\ %{}), to: Moderation
  defdelegate unban_user(user), to: Moderation
  defdelegate suspend_user(user, attrs), to: Moderation
  defdelegate unsuspend_user(user), to: Moderation
  defdelegate user_suspended?(user), to: Moderation
  defdelegate unsuspend_expired_users(), to: Moderation
  defdelegate update_user_admin_status(user, is_admin), to: Moderation
  defdelegate admin_create_user(attrs \\ %{}), to: Moderation
  defdelegate admin_update_user(user, attrs), to: Moderation
  defdelegate admin_delete_user(user), to: Moderation
  defdelegate change_user_admin(user, attrs \\ %{}), to: Moderation
  defdelegate change_user_admin_registration(user, attrs \\ %{}), to: Moderation

  # Account Deletion Requests
  defdelegate create_deletion_request(user, attrs \\ %{}), to: Moderation
  defdelegate get_pending_deletion_request(user), to: Moderation
  defdelegate list_deletion_requests(), to: Moderation
  defdelegate get_deletion_request!(id), to: Moderation
  defdelegate review_deletion_request(request, admin, status, attrs \\ %{}), to: Moderation

  ## Multi-Account Functions - Delegated to MultiAccount module

  defdelegate find_users_by_registration_ip(ip_address), to: MultiAccount
  defdelegate detect_multi_accounts(), to: MultiAccount
  defdelegate detect_multi_accounts_paginated(page, per_page), to: MultiAccount
  defdelegate search_multi_accounts_paginated(search_query, page, per_page), to: MultiAccount
  defdelegate search_multi_accounts(search_query), to: MultiAccount
  defdelegate get_user_with_ip_info!(id), to: MultiAccount

  ## Tracking Functions - Delegated to Tracking module

  defdelegate update_user_login_info(user, ip_address), to: Tracking
  defdelegate record_imap_access(user_id), to: Tracking
  defdelegate record_pop3_access(user_id), to: Tracking
  defdelegate update_last_seen(user_id), to: Tracking
  defdelegate update_last_seen_async(user_id), to: Tracking
  defdelegate update_user_status(user, status, message \\ nil), to: Tracking
  defdelegate get_user_status(user_id), to: Tracking

  ## Invite Codes

  @doc """
  Returns the list of invite codes.
  """
  def list_invite_codes do
    InviteCode
    |> order_by(desc: :inserted_at)
    |> preload(:created_by)
    |> Repo.all()
  end

  @doc """
  Gets a single invite code.

  Returns nil if the InviteCode does not exist.
  """
  def get_invite_code(id), do: Repo.get(InviteCode, id) |> Repo.preload(:created_by)

  @doc """
  Gets a single invite code.

  Raises if the InviteCode does not exist.
  """
  def get_invite_code!(id), do: Repo.get!(InviteCode, id) |> Repo.preload(:created_by)

  @doc """
  Gets an invite code by its code string.

  Returns nil if the InviteCode does not exist.
  """
  def get_invite_code_by_code(code) do
    normalized_code = InviteCode.normalize_code(code)

    InviteCode
    |> where([i], fragment("upper(?)", i.code) == ^normalized_code)
    |> preload(:created_by)
    |> Repo.one()
  end

  @doc """
  Creates an invite code.
  """
  def create_invite_code(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.into(%{})

    if blank_invite_code?(attrs["code"]) do
      create_generated_invite_code(attrs, 3)
    else
      %InviteCode{}
      |> InviteCode.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Updates an invite code.
  """
  def update_invite_code(%InviteCode{} = invite_code, attrs) do
    invite_code
    |> InviteCode.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an invite code.
  """
  def delete_invite_code(%InviteCode{} = invite_code) do
    Repo.delete(invite_code)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking invite code changes.
  """
  def change_invite_code(%InviteCode{} = invite_code, attrs \\ %{}) do
    InviteCode.changeset(invite_code, attrs)
  end

  @doc """
  Registers a new user and claims an invite code atomically.
  """
  def register_user_with_invite(attrs) do
    invite_code = extract_invite_code(attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Ecto.Multi.run(:invite_use, fn repo, %{user: user} ->
      claim_invite_code(repo, invite_code, user.id)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        maybe_create_user_mailbox(user)
        {:ok, Repo.get!(User, user.id)}

      {:error, :user, changeset, _changes_so_far} ->
        {:error, changeset}

      {:error, :invite_use, reason, _changes_so_far} ->
        {:error, invite_registration_changeset(attrs, reason)}
    end
  end

  @doc """
  Validates and uses an invite code for a user registration.
  """
  def use_invite_code(code, user_id) do
    Repo.transaction(fn ->
      case claim_invite_code(Repo, code, user_id) do
        {:ok, invite_code} -> invite_code
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, invite_code} -> {:ok, invite_code}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if an invite code is valid for use.
  """
  def validate_invite_code(code) do
    case get_invite_code_by_code(code) do
      nil ->
        {:error, :invalid_code}

      %InviteCode{} = invite_code ->
        if InviteCode.valid_for_use?(invite_code) do
          {:ok, invite_code}
        else
          cond do
            !invite_code.is_active -> {:error, :code_inactive}
            InviteCode.expired?(invite_code) -> {:error, :code_expired}
            InviteCode.exhausted?(invite_code) -> {:error, :code_exhausted}
            true -> {:error, :code_not_valid}
          end
        end
    end
  end

  @doc """
  Gets statistics for invite codes.
  """
  def get_invite_code_stats do
    now = DateTime.utc_now()

    %{
      total: Repo.aggregate(InviteCode, :count),
      active:
        Repo.aggregate(
          from(i in InviteCode,
            where:
              i.is_active == true and
                (is_nil(i.expires_at) or i.expires_at >= ^now) and
                i.uses_count < i.max_uses
          ),
          :count
        ),
      expired:
        Repo.aggregate(
          from(i in InviteCode,
            where: not is_nil(i.expires_at) and i.expires_at < ^now
          ),
          :count
        ),
      exhausted: Repo.aggregate(from(i in InviteCode, where: i.uses_count >= i.max_uses), :count)
    }
  end

  @doc """
  Returns the invite-code policy used by self-service invite creation.
  """
  def self_service_invite_policy do
    %{
      min_trust_level: Elektrine.System.self_service_invite_min_trust_level(),
      max_active_codes: @self_service_invite_active_limit,
      max_codes_per_month: @self_service_invite_monthly_generation_limit,
      max_uses_per_month: @self_service_invite_monthly_use_limit,
      max_uses: @self_service_invite_max_uses,
      expires_in_days: @self_service_invite_expiry_days
    }
  end

  @doc """
  Returns whether a user can create invite codes from account settings.
  """
  def user_can_create_invite_codes?(%User{} = user) do
    user.is_admin || user.trust_level >= self_service_invite_policy().min_trust_level
  end

  def user_can_create_invite_codes?(_), do: false

  @doc """
  Returns invite codes created by a specific user.
  """
  def list_user_invite_codes(user_id) do
    InviteCode
    |> where([i], i.created_by_id == ^user_id)
    |> order_by([i], desc: i.inserted_at)
    |> preload(:created_by)
    |> Repo.all()
  end

  @doc """
  Creates a constrained self-service invite code for a user.
  """
  def create_self_service_invite_code(%User{} = user, attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.into(%{})

    with :ok <- ensure_self_service_invites_enabled(),
         :ok <- authorize_self_service_invite_creation(user) do
      Repo.transaction(fn ->
        with :ok <- ensure_self_service_invite_creation_capacity(Repo, user),
             {:ok, invite_code} <-
               create_invite_code(%{
                 "created_by_id" => user.id,
                 "max_uses" => @self_service_invite_max_uses,
                 "expires_at" => self_service_invite_expiration(),
                 "note" => normalize_optional_string(attrs["note"])
               }) do
          invite_code
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, invite_code} -> {:ok, invite_code}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Deactivates a self-service invite code owned by the user.
  """
  def deactivate_self_service_invite_code(%User{} = user, invite_code_id)
      when is_integer(invite_code_id) do
    case get_user_invite_code(user.id, invite_code_id) do
      nil ->
        {:error, :not_found}

      invite_code ->
        update_invite_code(invite_code, %{is_active: false})
    end
  end

  ## Handle Management

  @doc """
  Get a user by handle.
  """
  def get_user_by_handle(handle) when is_binary(handle) do
    Repo.one(from u in User, where: fragment("lower(?)", u.handle) == ^String.downcase(handle))
  end

  @doc """
  Update a user's handle.
  Enforces 30-day cooldown and 90-day reservation.
  """
  def update_user_handle(%User{} = user, handle) do
    changeset = User.handle_changeset(user, %{handle: handle})

    Repo.transaction(fn ->
      case Repo.update(changeset) do
        {:ok, updated_user} ->
          # Record old handle in history if it changed
          if user.handle && user.handle != updated_user.handle do
            record_handle_history(user)
          end

          updated_user

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Update a user's display name.
  """
  def update_user_display_name(%User{} = user, display_name) do
    user
    |> User.handle_changeset(%{display_name: display_name})
    |> Repo.update()
  end

  @doc """
  Check if a handle is available for claiming.
  """
  def handle_available?(handle) when is_binary(handle) do
    User.handle_available?(handle)
  end

  @doc """
  Claim a handle for a user (used during grace period).
  Users get priority for their original username.
  """
  def claim_handle(%User{} = user, desired_handle) do
    desired_handle = String.downcase(desired_handle)

    cond do
      # User already has this handle
      user.handle && String.downcase(user.handle) == desired_handle ->
        {:ok, user}

      # Check if user has priority (their original username)
      has_priority_claim?(user, desired_handle) ->
        force_claim_handle(user, desired_handle)

      # Check if handle is available
      handle_available?(desired_handle) ->
        update_user_handle(user, desired_handle)

      true ->
        {:error, "Handle is not available"}
    end
  end

  # Check if user has priority claim (their original username)
  defp has_priority_claim?(user, handle) do
    String.downcase(user.username) == String.downcase(handle)
  end

  # Force claim a handle (bump current holder if necessary)
  defp force_claim_handle(user, handle) do
    Repo.transaction(fn ->
      # Find current holder
      current_holder = get_user_by_handle(handle)

      if current_holder && current_holder.id != user.id do
        # Generate alternative handle for current holder
        alt_handle = generate_alternative_handle(current_holder.username)

        # Update current holder
        {:ok, _} = update_user_handle(current_holder, alt_handle)
      end

      # Update requesting user
      case update_user_handle(user, handle) do
        {:ok, updated_user} -> updated_user
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Generate alternative handle for displaced user
  defp generate_alternative_handle(username) do
    base = String.downcase(username) |> String.slice(0..16)

    # Try numbered variants
    Enum.find(1..999, fn num ->
      handle = "#{base}#{num}"
      String.length(handle) <= 20 && handle_available?(handle)
    end) || "#{base}_#{:rand.uniform(9999)}"
  end

  # Record handle in history for 90-day reservation
  defp record_handle_history(%User{} = user) do
    if user.handle do
      # Mark previous history entry as ended
      from(h in "handle_history",
        where: h.user_id == ^user.id and is_nil(h.used_until),
        update: [
          set: [
            used_until: ^DateTime.utc_now(),
            reserved_until: ^(DateTime.utc_now() |> DateTime.add(90 * 24 * 60 * 60, :second))
          ]
        ]
      )
      |> Repo.update_all([])

      # Create new history entry
      Repo.insert_all("handle_history", [
        %{
          user_id: user.id,
          handle: user.handle,
          used_from: user.handle_changed_at || user.inserted_at,
          used_until: DateTime.utc_now(),
          reserved_until: DateTime.utc_now() |> DateTime.add(90 * 24 * 60 * 60, :second),
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])
    end
  end

  @doc """
  Get handle history for a user.
  """
  def get_user_handle_history(user_id) do
    from(h in "handle_history",
      where: h.user_id == ^user_id,
      order_by: [desc: h.used_from],
      select: %{
        handle: h.handle,
        used_from: h.used_from,
        used_until: h.used_until,
        reserved_until: h.reserved_until
      }
    )
    |> Repo.all()
  end

  ## Privacy Settings

  @doc """
  Checks if a user can add another user to a group/channel based on privacy settings.
  Returns {:ok, :allowed} or {:error, :privacy_restriction}
  """
  def can_add_to_group?(target_user, requesting_user) do
    check_privacy_permission(target_user, requesting_user, :allow_group_adds_from)
  end

  @doc """
  Checks if a user can send a direct message to another user based on privacy settings.
  Returns {:ok, :allowed} or {:error, :privacy_restriction}
  """
  def can_send_direct_message?(target_user, requesting_user) do
    check_privacy_permission(target_user, requesting_user, :allow_direct_messages_from)
  end

  @doc """
  Checks if a user can mention another user based on privacy settings.
  Returns {:ok, :allowed} or {:error, :privacy_restriction}
  """
  def can_mention?(target_user, requesting_user) do
    check_privacy_permission(target_user, requesting_user, :allow_mentions_from)
  end

  @doc """
  Checks if a user can view another user's profile based on privacy settings.
  Returns {:ok, :allowed} or {:error, :privacy_restriction}
  """
  def can_view_profile?(target_user, requesting_user) do
    setting = Map.get(target_user, :profile_visibility, "public")

    case setting do
      "public" ->
        {:ok, :allowed}

      "followers" ->
        cond do
          # If no requesting user (logged out), deny access
          requesting_user == nil ->
            {:error, :privacy_restriction}

          # If it's the user viewing their own profile, allow
          requesting_user.id == target_user.id ->
            {:ok, :allowed}

          # Check if requesting user follows target user
          following?(requesting_user.id, target_user.id) ->
            {:ok, :allowed}

          # Default case
          true ->
            {:error, :privacy_restriction}
        end

      "private" ->
        # Only allow the user to view their own profile
        if requesting_user && requesting_user.id == target_user.id do
          {:ok, :allowed}
        else
          {:error, :privacy_restriction}
        end

      _ ->
        # Default to public if setting is not recognized
        {:ok, :allowed}
    end
  end

  # Private helper function to check privacy permissions
  defp check_privacy_permission(target_user, requesting_user, field) do
    # Always allow users to access their own resources
    if requesting_user && requesting_user.id == target_user.id do
      {:ok, :allowed}
    else
      # If requesting user is nil (anonymous), only allow if setting is "everyone"
      if requesting_user == nil do
        setting = Map.get(target_user, field, "everyone")

        if setting == "everyone" do
          {:ok, :allowed}
        else
          {:error, :privacy_restriction}
        end
      else
        # Check the privacy setting
        setting = Map.get(target_user, field, "everyone")

        case setting do
          "everyone" ->
            {:ok, :allowed}

          "following" ->
            # Check if target user follows the requesting user
            if following?(target_user.id, requesting_user.id) do
              {:ok, :allowed}
            else
              {:error, :privacy_restriction}
            end

          "followers" ->
            # Check if requesting user follows the target user
            if following?(requesting_user.id, target_user.id) do
              {:ok, :allowed}
            else
              {:error, :privacy_restriction}
            end

          "mutual" ->
            # Check if both users follow each other
            if following?(target_user.id, requesting_user.id) &&
                 following?(requesting_user.id, target_user.id) do
              {:ok, :allowed}
            else
              {:error, :privacy_restriction}
            end

          "nobody" ->
            {:error, :privacy_restriction}

          _ ->
            # Default to most permissive for unknown values
            {:ok, :allowed}
        end
      end
    end
  end

  @doc """
  Checks if a user is following another user.
  """
  def following?(follower_id, followed_id) do
    # This assumes you have a follows/followers system.
    query =
      from f in "follows",
        where: f.follower_id == ^follower_id and f.followed_id == ^followed_id,
        select: true

    Repo.exists?(query)
  end

  # Record username change in history for 1-year blocking
  defp record_username_change(user_id, old_username, _new_username) do
    # Record the old username being abandoned
    history_attrs = %{
      user_id: user_id,
      username: old_username,
      previous_username: nil,
      changed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case %UsernameHistory{}
         |> UsernameHistory.changeset(history_attrs)
         |> Repo.insert() do
      {:ok, history_record} ->
        {:ok, history_record}

      {:error, changeset} ->
        Logger.error("Failed to record username history: #{inspect(changeset.errors)}")
        # Don't fail the username change if history recording fails
        {:error, changeset}
    end
  end

  # Updates the user's mailbox email address to match their new username.
  # This prevents duplicate mailboxes when usernames change.
  defp update_mailbox_email_for_username_change(user) do
    if email_module_compiled?() do
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
                Logger.error(
                  "Cannot create #{new_email} for user #{user.id} - email already taken"
                )

                :ok
            end
          else
            :ok
          end
      end
    else
      :ok
    end
  end

  defp maybe_create_user_mailbox(user) do
    if email_module_compiled?() do
      Elektrine.Email.create_mailbox(user)
    else
      :ok
    end
  end

  defp create_generated_invite_code(attrs, attempts_remaining) when attempts_remaining > 0 do
    generated_attrs = Map.put(attrs, "code", InviteCode.generate_code())

    case %InviteCode{} |> InviteCode.create_changeset(generated_attrs) |> Repo.insert() do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if autogenerated_code_collision?(changeset) and attempts_remaining > 1 do
          create_generated_invite_code(attrs, attempts_remaining - 1)
        else
          error
        end

      success ->
        success
    end
  end

  defp create_generated_invite_code(attrs, _attempts_remaining) do
    %InviteCode{}
    |> InviteCode.create_changeset(Map.put(attrs, "code", InviteCode.generate_code()))
    |> Repo.insert()
  end

  defp autogenerated_code_collision?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:code, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  defp claim_invite_code(repo, code, user_id) do
    case get_invite_code_for_update(repo, code) do
      nil ->
        {:error, :invalid_code}

      %InviteCode{} = invite_code ->
        case invite_code_validation_error(invite_code) do
          nil ->
            with :ok <- ensure_self_service_invite_use_capacity(repo, invite_code),
                 {:ok, _use} <- insert_invite_code_use(repo, invite_code.id, user_id),
                 {1, _} <- increment_invite_code_usage(repo, invite_code.id) do
              {:ok, %{invite_code | uses_count: invite_code.uses_count + 1}}
            else
              {:error, :monthly_invite_use_limit_reached} ->
                {:error, :monthly_invite_use_limit_reached}

              {:error, %Ecto.Changeset{} = changeset} ->
                {:error, invite_code_use_error(changeset)}

              {0, _} ->
                {:error, :code_exhausted}
            end

          reason ->
            {:error, reason}
        end
    end
  end

  defp get_invite_code_for_update(repo, code) do
    normalized_code = InviteCode.normalize_code(code)

    InviteCode
    |> where([i], fragment("upper(?)", i.code) == ^normalized_code)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp invite_code_validation_error(%InviteCode{} = invite_code) do
    cond do
      !invite_code.is_active -> :code_inactive
      InviteCode.expired?(invite_code) -> :code_expired
      InviteCode.exhausted?(invite_code) -> :code_exhausted
      true -> nil
    end
  end

  defp insert_invite_code_use(repo, invite_code_id, user_id) do
    %InviteCodeUse{}
    |> InviteCodeUse.changeset(%{invite_code_id: invite_code_id, user_id: user_id})
    |> repo.insert()
  end

  defp increment_invite_code_usage(repo, invite_code_id) do
    from(i in InviteCode,
      where: i.id == ^invite_code_id and i.uses_count < i.max_uses
    )
    |> repo.update_all(inc: [uses_count: 1])
  end

  defp invite_code_use_error(%Ecto.Changeset{} = changeset) do
    case Enum.find(changeset.errors, fn {field, _error} -> field == :user_id end) do
      {:user_id, {_message, opts}} ->
        if Keyword.get(opts, :constraint) == :unique do
          :already_used
        else
          :code_not_valid
        end

      _other ->
        :code_not_valid
    end
  end

  defp invite_registration_changeset(attrs, reason) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Ecto.Changeset.add_error(:invite_code, invite_code_error_message(reason))
  end

  defp invite_code_error_message(:invalid_code), do: "Invalid invite code"
  defp invite_code_error_message(:code_expired), do: "This invite code has expired"

  defp invite_code_error_message(:code_exhausted),
    do: "This invite code has reached its usage limit"

  defp invite_code_error_message(:code_inactive), do: "This invite code is no longer active"

  defp invite_code_error_message(:monthly_invite_use_limit_reached),
    do: "This invite code is temporarily unavailable right now"

  defp invite_code_error_message(:already_used),
    do: "This account has already used an invite code"

  defp invite_code_error_message(_reason), do: "Invalid invite code"

  defp extract_invite_code(attrs) when is_map(attrs) do
    Map.get(attrs, "invite_code") || Map.get(attrs, :invite_code)
  end

  defp blank_invite_code?(code) do
    is_nil(code) or String.trim(to_string(code)) == ""
  end

  defp ensure_self_service_invites_enabled do
    if Elektrine.System.invite_codes_enabled?() do
      :ok
    else
      {:error, :invite_codes_disabled}
    end
  end

  defp authorize_self_service_invite_creation(%User{} = user) do
    if user_can_create_invite_codes?(user) do
      :ok
    else
      {:error, :insufficient_trust_level}
    end
  end

  defp ensure_self_service_invite_creation_capacity(repo, %User{} = user) do
    user =
      case lock_user_for_update(repo, user.id) do
        %User{} = locked_user -> locked_user
        nil -> user
      end

    with :ok <- ensure_self_service_invite_capacity(repo, user.id),
         :ok <- ensure_self_service_monthly_generation_capacity(repo, user) do
      :ok
    end
  end

  defp ensure_self_service_invite_capacity(repo, user_id) do
    now = DateTime.utc_now()

    active_count =
      from(i in InviteCode,
        where:
          i.created_by_id == ^user_id and
            i.is_active == true and
            (is_nil(i.expires_at) or i.expires_at >= ^now) and
            i.uses_count < i.max_uses
      )
      |> repo.aggregate(:count)

    if active_count < @self_service_invite_active_limit do
      :ok
    else
      {:error, :invite_code_limit_reached}
    end
  end

  defp ensure_self_service_monthly_generation_capacity(_repo, %User{is_admin: true}), do: :ok

  defp ensure_self_service_monthly_generation_capacity(repo, %User{id: user_id}) do
    {month_start, next_month_start} = current_month_naive_window()

    generated_count =
      from(i in InviteCode,
        where:
          i.created_by_id == ^user_id and
            i.inserted_at >= ^month_start and
            i.inserted_at < ^next_month_start
      )
      |> repo.aggregate(:count)

    if generated_count < @self_service_invite_monthly_generation_limit do
      :ok
    else
      {:error, :monthly_invite_code_limit_reached}
    end
  end

  defp ensure_self_service_invite_use_capacity(_repo, %InviteCode{created_by_id: nil}), do: :ok

  defp ensure_self_service_invite_use_capacity(repo, %InviteCode{created_by_id: created_by_id}) do
    case lock_user_for_update(repo, created_by_id) do
      %User{} = creator -> ensure_self_service_monthly_use_capacity(repo, creator)
      nil -> :ok
    end
  end

  defp ensure_self_service_monthly_use_capacity(_repo, %User{is_admin: true}), do: :ok

  defp ensure_self_service_monthly_use_capacity(repo, %User{id: user_id}) do
    {month_start, next_month_start} = current_month_datetime_window()

    used_count =
      from(invite_use in InviteCodeUse,
        join: invite_code in InviteCode,
        on: invite_code.id == invite_use.invite_code_id,
        where:
          invite_code.created_by_id == ^user_id and
            invite_use.used_at >= ^month_start and
            invite_use.used_at < ^next_month_start
      )
      |> repo.aggregate(:count)

    if used_count < @self_service_invite_monthly_use_limit do
      :ok
    else
      {:error, :monthly_invite_use_limit_reached}
    end
  end

  defp lock_user_for_update(repo, user_id) do
    from(u in User,
      where: u.id == ^user_id,
      lock: "FOR UPDATE"
    )
    |> repo.one()
  end

  defp get_user_invite_code(user_id, invite_code_id) do
    InviteCode
    |> where([i], i.id == ^invite_code_id and i.created_by_id == ^user_id)
    |> preload(:created_by)
    |> Repo.one()
  end

  defp self_service_invite_expiration do
    DateTime.utc_now()
    |> DateTime.add(@self_service_invite_expiry_days * @seconds_per_day, :second)
    |> DateTime.truncate(:second)
  end

  defp current_month_naive_window do
    {month_start, next_month_start} = current_month_date_window()

    {
      NaiveDateTime.new!(month_start, ~T[00:00:00]),
      NaiveDateTime.new!(next_month_start, ~T[00:00:00])
    }
  end

  defp current_month_datetime_window do
    {month_start, next_month_start} = current_month_date_window()

    {
      DateTime.new!(month_start, ~T[00:00:00], "Etc/UTC"),
      DateTime.new!(next_month_start, ~T[00:00:00], "Etc/UTC")
    }
  end

  defp current_month_date_window do
    month_start = Date.utc_today() |> Date.beginning_of_month()
    next_month_start = month_start |> Date.end_of_month() |> Date.add(1)
    {month_start, next_month_start}
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp maybe_delete_email_data(user) do
    if email_module_compiled?() do
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
    else
      :ok
    end
  end

  defp email_module_compiled? do
    Modules.compiled?(:email)
  end
end
