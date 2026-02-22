defmodule Elektrine.Accounts.User do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  schema "users" do
    # Authentication
    field :username, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
    field :current_password, :string, virtual: true
    field :invite_code, :string, virtual: true
    field :avatar, :string
    field :avatar_size, :integer, default: 0
    field :is_admin, :boolean, default: false
    field :verified, :boolean, default: false
    field :banned, :boolean, default: false
    field :banned_at, :utc_datetime
    field :banned_reason, :string
    field :suspended, :boolean, default: false
    field :suspended_until, :utc_datetime
    field :suspension_reason, :string

    # Trust Level System
    field :trust_level, :integer, default: 0
    field :trust_level_locked, :boolean, default: false
    field :promoted_at, :utc_datetime
    field :two_factor_enabled, :boolean, default: false
    field :two_factor_secret, :string
    field :two_factor_backup_codes, {:array, :string}
    field :two_factor_enabled_at, :utc_datetime
    field :registration_ip, :string
    field :registered_via_onion, :boolean, default: false
    field :last_login_ip, :string
    field :last_login_at, :utc_datetime
    field :login_count, :integer, default: 0
    field :recovery_email, :string
    field :password_reset_token, :string
    field :password_reset_token_expires_at, :utc_datetime
    field :last_password_change, :utc_datetime
    field :locale, :string, default: "en"
    field :timezone, :string
    field :time_format, :string, default: "12"

    # Social Identity
    field :handle, :string
    field :display_name, :string
    field :unique_id, :string
    field :handle_changed_at, :utc_datetime

    # Privacy Settings
    field :allow_group_adds_from, :string, default: "everyone"
    field :allow_direct_messages_from, :string, default: "everyone"
    field :allow_mentions_from, :string, default: "everyone"
    field :allow_calls_from, :string, default: "friends"
    field :allow_friend_requests_from, :string, default: "everyone"
    field :profile_visibility, :string, default: "public"
    field :default_post_visibility, :string, default: "followers"

    # Notification Settings
    field :notify_on_new_follower, :boolean, default: true
    field :notify_on_direct_message, :boolean, default: true
    field :notify_on_mention, :boolean, default: true
    field :notify_on_reply, :boolean, default: true
    field :notify_on_like, :boolean, default: true
    field :notify_on_email_received, :boolean, default: true
    field :notify_on_discussion_reply, :boolean, default: true
    field :notify_on_comment, :boolean, default: true

    # Storage Tracking
    field :storage_used_bytes, :integer, default: 0
    # 500MB
    field :storage_limit_bytes, :integer, default: 524_288_000
    field :storage_last_calculated_at, :utc_datetime

    # CardDAV/CalDAV sync
    field :addressbook_ctag, :string

    # Email Protocol Usage Tracking
    field :last_imap_access, :utc_datetime
    field :last_pop3_access, :utc_datetime

    # User Status
    field :status, :string, default: "online"
    field :status_message, :string
    field :status_updated_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    # Email Settings
    field :email_signature, :string
    field :preferred_email_domain, :string, default: "z.org"

    # Email Sending Restrictions (anti-spam)
    field :email_sending_restricted, :boolean, default: false
    field :email_rate_limit_violations, :integer, default: 0
    field :email_restriction_reason, :string
    field :email_restricted_at, :utc_datetime
    field :recovery_email_verified, :boolean, default: false
    field :recovery_email_verification_token, :string
    field :recovery_email_verification_sent_at, :utc_datetime

    # Onboarding
    field :onboarding_completed, :boolean, default: false
    field :onboarding_completed_at, :utc_datetime
    field :onboarding_step, :integer, default: 1

    # ActivityPub Federation
    field :activitypub_enabled, :boolean, default: true
    field :activitypub_private_key, :string
    field :activitypub_public_key, :string
    field :activitypub_manually_approve_followers, :boolean, default: true

    # Bluesky Cross-posting
    field :bluesky_enabled, :boolean, default: false
    field :bluesky_identifier, :string
    field :bluesky_app_password, :string
    field :bluesky_did, :string
    field :bluesky_pds_url, :string
    field :bluesky_inbound_cursor, :string
    field :bluesky_inbound_last_polled_at, :utc_datetime

    # PGP/OpenPGP Encryption
    field :pgp_public_key, :string
    field :pgp_key_id, :string
    field :pgp_fingerprint, :string
    field :pgp_key_uploaded_at, :utc_datetime
    field :pgp_wkd_hash, :string

    has_one :profile, Elektrine.Profiles.UserProfile
    has_many :badges, Elektrine.Profiles.UserBadge, foreign_key: :user_id
    has_one :activity_stats, Elektrine.Accounts.UserActivityStats
    has_many :trust_level_logs, Elektrine.Accounts.TrustLevelLog

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for user registration.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :password,
      :password_confirmation,
      :invite_code,
      :registration_ip,
      :registered_via_onion
    ])
    |> validate_tos_agreement(attrs)
    |> normalize_username()
    |> validate_required([:username, :password, :password_confirmation])
    |> validate_length(:username, min: 2, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9]+$/, message: "only letters and numbers allowed")
    |> validate_username_not_alias()
    |> validate_username_not_reserved()
    |> validate_username_case_conflicts()
    |> unique_constraint(:username,
      name: :users_username_ci_unique,
      message: "this username is already taken"
    )
    |> unique_constraint(:username,
      name: :users_username_index,
      message: "this username is already taken"
    )
    |> validate_length(:password, min: 8, max: 72)
    |> validate_confirmation(:password, message: "does not match password")
    |> generate_unique_id()
    |> assign_initial_handle()
    |> put_display_name_from_username()
    |> hash_password()
  end

  @doc """
  Changeset for admin user registration.
  Allows admins to create users with additional options.
  """
  def admin_registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password, :password_confirmation, :is_admin])
    |> normalize_username()
    |> validate_required([:username, :password, :password_confirmation])
    |> validate_length(:username, min: 2, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9]+$/, message: "only letters and numbers allowed")
    |> validate_username_not_alias()
    # Skip reserved username validation for admin-created users
    |> validate_username_case_conflicts()
    |> unique_constraint(:username,
      name: :users_username_ci_unique,
      message: "this username is already taken (case-insensitive)"
    )
    |> validate_length(:password, min: 8, max: 72)
    |> validate_confirmation(:password, message: "does not match password")
    |> generate_unique_id()
    |> assign_initial_handle()
    |> put_display_name_from_username()
    |> hash_password()
  end

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    change(changeset, %{
      password_hash: Argon2.hash_pwd_salt(password),
      last_password_change: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp hash_password(changeset), do: changeset

  # Generate a unique ID for the user
  defp generate_unique_id(changeset) do
    if get_field(changeset, :unique_id) do
      changeset
    else
      # 8 bytes = 64 bits entropy
      # 50% collision probability at ~5 billion users (vs 77k with 4 bytes)
      unique_id = "usr_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
      put_change(changeset, :unique_id, unique_id)
    end
  end

  # Assign an initial handle based on username
  defp assign_initial_handle(changeset) do
    if get_field(changeset, :handle) do
      changeset
    else
      username = get_field(changeset, :username)

      if username do
        base_handle = String.downcase(username)
        handle = find_available_handle(base_handle)
        put_change(changeset, :handle, handle)
      else
        changeset
      end
    end
  end

  # Find an available handle by appending numbers if needed
  defp find_available_handle(base_handle, attempt \\ 0) do
    handle =
      if attempt == 0 do
        base_handle
      else
        "#{base_handle}#{attempt}"
      end

    # Check if handle is already taken (use exists? to avoid multiple results error)
    import Ecto.Query
    exists = Elektrine.Repo.exists?(from u in __MODULE__, where: u.handle == ^handle)

    if exists do
      find_available_handle(base_handle, attempt + 1)
    else
      handle
    end
  end

  # Set display name from username if not provided
  defp put_display_name_from_username(changeset) do
    if get_field(changeset, :display_name) do
      changeset
    else
      username = get_field(changeset, :username)

      if username do
        put_change(changeset, :display_name, username)
      else
        changeset
      end
    end
  end

  @doc """
  A changeset for changing the user account.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :avatar,
      :avatar_size,
      :display_name,
      :recovery_email,
      :allow_group_adds_from,
      :allow_direct_messages_from,
      :allow_mentions_from,
      :allow_calls_from,
      :allow_friend_requests_from,
      :profile_visibility,
      :default_post_visibility,
      :notify_on_new_follower,
      :notify_on_direct_message,
      :notify_on_mention,
      :notify_on_reply,
      :notify_on_like,
      :notify_on_email_received,
      :notify_on_discussion_reply,
      :notify_on_comment,
      :locale,
      :timezone,
      :time_format,
      :email_signature,
      :preferred_email_domain,
      :onboarding_completed,
      :onboarding_completed_at,
      :onboarding_step,
      :activitypub_manually_approve_followers,
      :bluesky_enabled,
      :bluesky_identifier,
      :bluesky_app_password,
      :bluesky_pds_url
    ])
    |> validate_length(:display_name, max: 100)
    |> validate_format(:recovery_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address with @ symbol and domain"
    )
    |> validate_length(:recovery_email, max: 160)
    |> validate_length(:email_signature, max: 500)
    |> validate_inclusion(:allow_group_adds_from, [
      "everyone",
      "following",
      "followers",
      "mutual",
      "friends",
      "nobody"
    ])
    |> validate_inclusion(:allow_direct_messages_from, [
      "everyone",
      "following",
      "followers",
      "mutual",
      "friends",
      "nobody"
    ])
    |> validate_inclusion(:allow_mentions_from, [
      "everyone",
      "following",
      "followers",
      "mutual",
      "friends",
      "nobody"
    ])
    |> validate_inclusion(:allow_calls_from, ["everyone", "friends", "nobody"])
    |> validate_inclusion(:allow_friend_requests_from, ["everyone", "followers", "nobody"])
    |> validate_inclusion(:profile_visibility, ["public", "followers", "private"])
    |> validate_inclusion(:default_post_visibility, ["public", "followers", "friends", "private"])
    |> validate_inclusion(:locale, ~w(en zh), message: "is not a supported locale")
    |> validate_inclusion(:time_format, ~w(12 24), message: "must be 12 or 24")
    |> validate_inclusion(:preferred_email_domain, ~w(elektrine.com z.org),
      message: "must be elektrine.com or z.org"
    )
    |> validate_bluesky_settings()
  end

  @doc """
  A changeset for changing the user password.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation, :current_password])
    |> validate_required([:password, :password_confirmation, :current_password])
    |> validate_length(:password, min: 8, max: 72)
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_current_password()
    |> hash_password()
  end

  @doc """
  A changeset for importing users with pre-hashed passwords.
  For use in migrations only.
  """
  def import_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password_hash])
    |> normalize_username()
    |> validate_required([:username, :password_hash])
    |> validate_length(:username, min: 2, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9]+$/, message: "only letters and numbers allowed")
    |> unique_constraint(:username)
  end

  @doc """
  A changeset for admin user editing.
  """
  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :avatar,
      :handle,
      :display_name,
      :recovery_email,
      :locale,
      :timezone,
      :time_format,
      :verified,
      :banned,
      :banned_reason,
      :suspended,
      :suspended_until,
      :suspension_reason,
      :is_admin,
      :trust_level,
      :trust_level_locked
    ])
    |> validate_required([:username])
    |> normalize_username()
    |> validate_length(:username, min: 2, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9]+$/, message: "only letters and numbers allowed")
    |> validate_handle()
    |> validate_length(:display_name, max: 100)
    |> validate_format(:recovery_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email"
    )
    |> validate_inclusion(:locale, ["en", "zh"])
    |> validate_inclusion(:time_format, ["12", "24"])
    |> validate_length(:banned_reason, max: 500)
    |> validate_length(:suspension_reason, max: 500)
    |> validate_number(:trust_level, greater_than_or_equal_to: 0, less_than_or_equal_to: 4)
    |> maybe_set_ban_timestamp()
    |> maybe_clear_suspension_data()
    |> validate_username_not_alias()
    |> unique_constraint(:handle,
      name: :users_handle_ci_unique,
      message: "this handle is already taken"
    )
    |> validate_username_not_reserved()
    |> validate_username_case_conflicts()
    |> unique_constraint(:username,
      name: :users_username_ci_unique,
      message: "this username is already taken"
    )
    |> unique_constraint(:username,
      name: :users_username_index,
      message: "this username is already taken"
    )
  end

  # Set banned_at timestamp when banned status changes
  defp maybe_set_ban_timestamp(changeset) do
    case get_change(changeset, :banned) do
      true -> put_change(changeset, :banned_at, DateTime.utc_now())
      false -> put_change(changeset, :banned_at, nil) |> put_change(:banned_reason, nil)
      _ -> changeset
    end
  end

  # Clear suspension data when suspension is disabled
  defp maybe_clear_suspension_data(changeset) do
    case get_change(changeset, :suspended) do
      false ->
        changeset
        |> put_change(:suspended_until, nil)
        |> put_change(:suspension_reason, nil)

      _ ->
        changeset
    end
  end

  @doc """
  A changeset for banning a user.
  """
  def ban_changeset(user, attrs \\ %{}) do
    user
    |> cast(attrs, [:banned_reason])
    |> put_change(:banned, true)
    |> put_change(:banned_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  A changeset for updating user locale preference.
  """
  def locale_changeset(user, attrs) do
    user
    |> cast(attrs, [:locale, :timezone, :time_format])
    |> validate_inclusion(:locale, ~w(en zh), message: "is not a supported locale")
    |> validate_inclusion(:time_format, ~w(12 24), message: "must be 12 or 24")
  end

  @doc """
  A changeset for unbanning a user.
  """
  def unban_changeset(user, attrs \\ %{}) do
    user
    |> cast(attrs, [])
    |> put_change(:banned, false)
    |> put_change(:banned_at, nil)
    |> put_change(:banned_reason, nil)
  end

  @doc """
  A changeset for suspending a user.
  """
  def suspend_changeset(user, attrs) do
    user
    |> cast(attrs, [:suspension_reason, :suspended_until])
    |> validate_length(:suspension_reason, max: 500)
    |> put_change(:suspended, true)
  end

  @doc """
  A changeset for unsuspending a user.
  """
  def unsuspend_changeset(user, attrs \\ %{}) do
    user
    |> cast(attrs, [])
    |> put_change(:suspended, false)
    |> put_change(:suspended_until, nil)
    |> put_change(:suspension_reason, nil)
  end

  @doc """
  A changeset for enabling two-factor authentication.
  """
  def enable_two_factor_changeset(user, attrs) do
    user
    |> cast(attrs, [:two_factor_secret, :two_factor_backup_codes])
    |> validate_required([:two_factor_secret, :two_factor_backup_codes])
    |> put_change(:two_factor_enabled, true)
    |> put_change(:two_factor_enabled_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  A changeset for disabling two-factor authentication.
  """
  def disable_two_factor_changeset(user, _attrs \\ %{}) do
    user
    |> cast(%{}, [])
    |> put_change(:two_factor_enabled, false)
    |> put_change(:two_factor_secret, nil)
    |> put_change(:two_factor_backup_codes, nil)
    |> put_change(:two_factor_enabled_at, nil)
  end

  @doc """
  A changeset for updating backup codes after one is used.
  """
  def update_backup_codes_changeset(user, remaining_codes) do
    user
    |> cast(%{}, [])
    |> put_change(:two_factor_backup_codes, remaining_codes)
  end

  @doc """
  A changeset for updating login information.
  """
  def login_changeset(user, attrs) do
    user
    |> cast(attrs, [:last_login_ip, :last_login_at, :login_count])
  end

  # Private helper functions

  defp validate_tos_agreement(changeset, attrs) do
    # Only validate if this is a form submission (attrs has string keys and values)
    # Skip validation on initial changeset creation
    if is_map(attrs) && map_size(attrs) > 0 && Map.has_key?(attrs, "username") do
      case Map.get(attrs, "agree_to_terms") do
        "true" ->
          changeset

        _ ->
          add_error(
            changeset,
            :agree_to_terms,
            "You must agree to the Terms of Service and Privacy Policy"
          )
      end
    else
      changeset
    end
  end

  defp validate_username_not_alias(changeset) do
    username = get_field(changeset, :username)

    if username do
      # Check if this username would conflict with existing aliases on our domains
      allowed_domains = ["elektrine.com", "z.org"]

      # Check each domain for conflicts (case-insensitive)
      conflicts =
        Enum.any?(allowed_domains, fn domain ->
          alias_email = String.downcase("#{username}@#{domain}")

          query =
            from(a in Elektrine.Email.Alias,
              where: fragment("lower(?)", a.alias_email) == ^alias_email and a.enabled == true,
              limit: 1
            )

          case Elektrine.Repo.one(query) do
            nil -> false
            _alias -> true
          end
        end)

      if conflicts do
        add_error(changeset, :username, "this username conflicts with an existing email alias")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp validate_username_case_conflicts(changeset) do
    username = get_field(changeset, :username)
    user_id = get_field(changeset, :id)

    if username do
      # Check for case-insensitive duplicates
      query =
        from(u in Elektrine.Accounts.User,
          where: fragment("lower(?)", u.username) == ^String.downcase(username)
        )

      # Exclude current user if updating
      query =
        if user_id do
          from(u in query, where: u.id != ^user_id)
        else
          query
        end

      case Elektrine.Repo.one(query) do
        nil ->
          changeset

        _existing ->
          add_error(
            changeset,
            :username,
            "a user with this username already exists (case-insensitive check)"
          )
      end
    else
      changeset
    end
  end

  defp validate_current_password(changeset) do
    current_password = get_change(changeset, :current_password)

    if current_password do
      user = changeset.data

      # Verify the current password
      if verify_password(current_password, user.password_hash) do
        changeset
      else
        add_error(changeset, :current_password, "is incorrect")
      end
    else
      changeset
    end
  end

  # Helper function to verify password against hash
  defp verify_password(password, hash) when is_binary(password) and is_binary(hash) do
    if String.starts_with?(hash, ["$2", "$2a$", "$2b$", "$2y$"]) do
      Bcrypt.verify_pass(password, hash)
    else
      Argon2.verify_pass(password, hash)
    end
  end

  defp verify_password(_, _), do: false

  defp validate_username_not_reserved(changeset) do
    username = get_field(changeset, :username)

    if username do
      # List of reserved/sensitive usernames
      reserved_usernames = [
        # System accounts (critical - these would create system emails)
        "admin",
        "administrator",
        "root",
        "system",
        "daemon",
        "postmaster",
        "webmaster",
        "hostmaster",
        # Service accounts
        "support",
        "help",
        "contact",
        "info",
        "sales",
        "billing",
        "noreply",
        "no-reply",
        "donotreply",
        "do-not-reply",
        # ActivityPub endpoints (critical - would break federation)
        "inbox",
        "outbox",
        "followers",
        "following",
        "actor",
        "users",
        "activities",
        "ap",
        # Well-known paths
        "webfinger",
        ".well-known",
        "nodeinfo",
        # Federation-related
        "relay",
        "instance",
        "sharedInbox",
        "abuse",
        "security",
        "privacy",
        "legal",
        "compliance",
        "audit",
        # Technical infrastructure
        "api",
        "www",
        "mail",
        "email",
        "smtp",
        "pop",
        "imap",
        "ftp",
        "ssh",
        "git",
        "dev",
        "test",
        "staging",
        "prod",
        # Social/Marketing
        "marketing",
        "news",
        "newsletter",
        "notifications",
        "social",
        "media",
        "press",
        "blog",
        "forum",
        # Brand protection
        "elektrine",
        "z",
        "zorg",
        "official",
        "verified",
        # Common exploits
        "null",
        "undefined",
        "nil",
        "void",
        "empty",
        "blank",
        "anonymous",
        "guest",
        "user",
        "member",
        "public",
        # Application routes (prevent username/route conflicts)
        "chat",
        "timeline",
        "discussions",
        "friends",
        "search",
        "hashtag",
        "vpn",
        "account",
        "login",
        "register",
        "password",
        "logout",
        "onboarding",
        "about",
        "terms",
        "faq",
        "locale",
        "unsubscribe",
        "resubscribe",
        "pripyat",
        "badges",
        "reports",
        "updates",
        "storage",
        "profile",
        "settings",
        "invite",
        "invites",
        "l",
        "haraka"
      ]

      if String.downcase(username) in reserved_usernames do
        add_error(changeset, :username, "this username is reserved and cannot be used")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp normalize_username(changeset) do
    case get_field(changeset, :username) do
      nil ->
        changeset

      username ->
        normalized = String.downcase(username)
        put_change(changeset, :username, normalized)
    end
  end

  defp validate_bluesky_settings(changeset) do
    changeset
    |> normalize_optional_string(:bluesky_identifier)
    |> normalize_optional_string(:bluesky_app_password)
    |> normalize_optional_string(:bluesky_pds_url)
    |> validate_length(:bluesky_identifier, max: 255)
    |> validate_length(:bluesky_app_password, max: 255)
    |> validate_length(:bluesky_pds_url, max: 255)
    |> require_bluesky_credentials_when_enabled()
  end

  defp normalize_optional_string(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> put_change(changeset, field, nil)
          trimmed -> put_change(changeset, field, trimmed)
        end

      _ ->
        changeset
    end
  end

  defp require_bluesky_credentials_when_enabled(changeset) do
    if get_field(changeset, :bluesky_enabled) do
      changeset
      |> require_bluesky_identifier()
      |> require_bluesky_app_password()
    else
      changeset
    end
  end

  defp require_bluesky_identifier(changeset) do
    case get_field(changeset, :bluesky_identifier) do
      identifier when is_binary(identifier) and identifier != "" ->
        changeset

      _ ->
        add_error(changeset, :bluesky_identifier, "is required when Bluesky is enabled")
    end
  end

  defp require_bluesky_app_password(changeset) do
    case get_field(changeset, :bluesky_app_password) do
      password when is_binary(password) and password != "" ->
        changeset

      _ ->
        add_error(changeset, :bluesky_app_password, "is required when Bluesky is enabled")
    end
  end

  @doc """
  A changeset for updating recovery email.
  """
  def recovery_email_changeset(user, attrs) do
    user
    |> cast(attrs, [:recovery_email])
    |> validate_format(:recovery_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address with @ symbol and domain"
    )
    |> validate_length(:recovery_email, max: 160)
  end

  @doc """
  A changeset for initiating password reset.
  """
  def password_reset_changeset(user, token) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    user
    |> cast(%{}, [])
    |> put_change(:password_reset_token, token)
    |> put_change(:password_reset_token_expires_at, expires_at)
  end

  @doc """
  A changeset for clearing password reset token.
  """
  def clear_password_reset_changeset(user) do
    user
    |> cast(%{}, [])
    |> put_change(:password_reset_token, nil)
    |> put_change(:password_reset_token_expires_at, nil)
  end

  @doc """
  A changeset for resetting password with token.
  """
  def password_reset_with_token_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password, :password_confirmation])
    |> validate_length(:password, min: 8, max: 72)
    |> validate_confirmation(:password, message: "does not match password")
    |> hash_password()
    |> put_change(:password_reset_token, nil)
    |> put_change(:password_reset_token_expires_at, nil)
  end

  @doc """
  Checks if a password reset token is valid and not expired.
  """
  def valid_password_reset_token?(%__MODULE__{password_reset_token: nil}), do: false
  def valid_password_reset_token?(%__MODULE__{password_reset_token_expires_at: nil}), do: false

  def valid_password_reset_token?(%__MODULE__{password_reset_token_expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :lt
  end

  @doc """
  Returns the number of days since the user last changed their password.
  Returns nil if password change date is not available.
  """
  def days_since_password_change(%__MODULE__{last_password_change: nil}), do: nil

  def days_since_password_change(%__MODULE__{last_password_change: last_change}) do
    DateTime.diff(DateTime.utc_now(), last_change, :day)
  end

  @doc """
  Checks if a user's password is older than the specified number of days.
  """
  def password_expired?(%__MODULE__{} = user, max_days) when is_integer(max_days) do
    case days_since_password_change(user) do
      # No password change date available, assume not expired
      nil -> false
      days -> days > max_days
    end
  end

  @doc """
  Admin changeset for resetting user password.
  """
  def admin_password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    |> hash_password()
    |> put_change(:password_reset_token, nil)
    |> put_change(:password_reset_token_expires_at, nil)
  end

  @doc """
  Admin changeset for resetting user 2FA.
  """
  def admin_2fa_reset_changeset(user) do
    user
    |> cast(%{}, [])
    |> put_change(:two_factor_enabled, false)
    |> put_change(:two_factor_secret, nil)
    |> put_change(:two_factor_backup_codes, nil)
    |> put_change(:two_factor_enabled_at, nil)
  end

  @doc """
  Changeset for updating social handle.
  """
  def handle_changeset(user, attrs) do
    user
    |> cast(attrs, [:handle, :display_name])
    |> validate_handle()
    |> validate_handle_change_frequency()
    |> validate_display_name()
    |> unique_constraint(:handle,
      name: :users_handle_ci_unique,
      message: "this handle is already taken"
    )
  end

  @doc """
  Admin changeset for initial handle assignment during migration.
  """
  def admin_handle_changeset(user, attrs) do
    user
    |> cast(attrs, [:handle, :display_name, :unique_id])
    |> validate_handle()
    |> validate_display_name()
    |> validate_unique_id()
    |> unique_constraint(:handle,
      name: :users_handle_ci_unique,
      message: "this handle is already taken"
    )
    |> unique_constraint(:unique_id,
      name: :users_unique_id_unique,
      message: "unique ID collision"
    )
  end

  # Validate handle format: 1-20 chars, alphanumeric + underscore
  defp validate_handle(changeset) do
    changeset
    |> validate_required([:handle])
    |> validate_length(:handle, min: 1, max: 20)
    |> validate_format(:handle, ~r/^[a-zA-Z0-9_]+$/,
      message: "can only contain letters, numbers, and underscores"
    )
    |> validate_handle_not_reserved()
    |> normalize_handle()
  end

  # Normalize handle to lowercase for uniqueness checks
  defp normalize_handle(changeset) do
    case get_change(changeset, :handle) do
      nil -> changeset
      handle -> put_change(changeset, :handle, String.downcase(handle))
    end
  end

  # Check if handle is reserved
  defp validate_handle_not_reserved(changeset) do
    handle = get_field(changeset, :handle)

    if handle do
      reserved_handles = [
        "admin",
        "administrator",
        "root",
        "system",
        "moderator",
        "mod",
        "support",
        "help",
        "contact",
        "info",
        "api",
        "www",
        "mail",
        "blog",
        "news",
        "about",
        "legal",
        "privacy",
        "terms",
        "tos",
        "security",
        "abuse",
        "noreply",
        "no-reply",
        "elektrine",
        "official",
        # ActivityPub endpoints
        "inbox",
        "outbox",
        "followers",
        "following",
        "actor",
        "users",
        "activities",
        "ap",
        "relay",
        "instance",
        "webfinger",
        "nodeinfo"
      ]

      if String.downcase(handle) in reserved_handles do
        add_error(changeset, :handle, "this handle is reserved")
      else
        # Also check if it's in the handle_history reservation period
        validate_handle_not_recently_used(changeset, handle)
      end
    else
      changeset
    end
  end

  # Check if handle was recently used by another user (90-day reservation)
  defp validate_handle_not_recently_used(changeset, handle) do
    user_id = get_field(changeset, :id)

    # Check handle history for recent usage
    _ninety_days_ago = DateTime.utc_now() |> DateTime.add(-90 * 24 * 60 * 60, :second)

    query =
      from h in "handle_history",
        where: fragment("lower(?)", h.handle) == ^String.downcase(handle),
        where: h.user_id != ^user_id,
        where: is_nil(h.reserved_until) or h.reserved_until > ^DateTime.utc_now(),
        select: h.id,
        limit: 1

    case Elektrine.Repo.one(query) do
      nil ->
        changeset

      _reserved ->
        add_error(changeset, :handle, "this handle is reserved for 90 days after last use")
    end
  end

  # Validate handle change frequency (once per 30 days)
  defp validate_handle_change_frequency(changeset) do
    handle_changed_at = get_field(changeset, :handle_changed_at)

    if handle_changed_at && get_change(changeset, :handle) do
      thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30 * 24 * 60 * 60, :second)

      if DateTime.compare(handle_changed_at, thirty_days_ago) == :gt do
        days_remaining = DateTime.diff(handle_changed_at, thirty_days_ago, :day)

        add_error(
          changeset,
          :handle,
          "can only be changed once every 30 days. #{days_remaining} days remaining"
        )
      else
        # Update the change timestamp
        put_change(
          changeset,
          :handle_changed_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )
      end
    else
      # First time setting handle or no change
      if get_change(changeset, :handle) do
        put_change(
          changeset,
          :handle_changed_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )
      else
        changeset
      end
    end
  end

  # Validate display name
  defp validate_display_name(changeset) do
    changeset
    |> validate_length(:display_name, max: 50)
    |> validate_format(:display_name, ~r/^[^\n\r\t\x00-\x1F\x7F]+$/u,
      message: "cannot contain control characters"
    )
  end

  # Validate unique_id format
  defp validate_unique_id(changeset) do
    changeset
    |> validate_required([:unique_id])
    |> validate_format(:unique_id, ~r/^usr_[a-f0-9]{8}$/, message: "invalid unique ID format")
  end

  @doc """
  Check if a handle is available.
  """
  def handle_available?(handle) when is_binary(handle) do
    handle = String.downcase(handle)

    # Check if handle exists
    # Check if handle is reserved
    !Elektrine.Repo.exists?(
      from u in __MODULE__, where: fragment("lower(?)", u.handle) == ^handle
    ) &&
      !handle_reserved?(handle)
  end

  defp handle_reserved?(handle) do
    _ninety_days_ago = DateTime.utc_now() |> DateTime.add(-90 * 24 * 60 * 60, :second)

    Elektrine.Repo.exists?(
      from h in "handle_history",
        where: fragment("lower(?)", h.handle) == ^String.downcase(handle),
        where: is_nil(h.reserved_until) or h.reserved_until > ^DateTime.utc_now(),
        select: h.id
    )
  end
end
