defmodule Elektrine.Email.Alias do
  @moduledoc """
  Schema for email aliases with comprehensive validation and forwarding chain protection.
  Supports multiple aliases per user with loop detection, domain restrictions, and reserved address protection.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User

  schema "email_aliases" do
    field :alias_email, :string
    field :target_email, :string
    field :enabled, :boolean, default: true
    field :description, :string

    belongs_to :user, User

    timestamps()
  end

  def changeset(alias, attrs) do
    alias
    |> cast(attrs, [:alias_email, :target_email, :enabled, :description, :user_id])
    |> normalize_alias_email()
    |> validate_required([:alias_email, :user_id])
    |> validate_format(:alias_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email format"
    )
    |> validate_alias_local_part()
    |> validate_alias_domain()
    |> validate_no_case_conflicts()
    |> validate_alias_not_mailbox()
    |> validate_optional_target_email()
    |> validate_alias_limit()
    |> validate_one_alias_per_domain()
    |> validate_no_forwarding_loops()
    |> validate_length(:alias_email, max: 255)
    |> validate_length(:target_email, max: 255)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:alias_email,
      name: :email_aliases_alias_email_ci_unique,
      message: "this alias is already taken (case-insensitive)"
    )
    |> validate_alias_not_target()
    |> validate_not_reserved_address()
  end

  defp validate_no_case_conflicts(changeset) do
    alias_email = get_field(changeset, :alias_email)
    alias_id = get_field(changeset, :id)

    if alias_email do
      # Check for case-insensitive duplicates
      query =
        from(a in Elektrine.Email.Alias,
          where: fragment("lower(?)", a.alias_email) == ^String.downcase(alias_email)
        )

      # Exclude current record if updating
      query =
        if alias_id do
          from(a in query, where: a.id != ^alias_id)
        else
          query
        end

      case Elektrine.Repo.one(query) do
        nil ->
          changeset

        _existing ->
          add_error(
            changeset,
            :alias_email,
            "an alias with this email already exists (case-insensitive check)"
          )
      end
    else
      changeset
    end
  end

  defp validate_alias_domain(changeset) do
    alias_email = get_field(changeset, :alias_email)

    if alias_email do
      # Extract domain from email
      case String.split(alias_email, "@") do
        [_local, domain] ->
          allowed_domains = ["elektrine.com", "z.org"]

          if String.downcase(domain) in allowed_domains do
            changeset
          else
            add_error(
              changeset,
              :alias_email,
              "must use one of the allowed domains: #{Enum.join(allowed_domains, ", ")}"
            )
          end

        _ ->
          # Invalid email format, but this will be caught by the format validation
          changeset
      end
    else
      changeset
    end
  end

  defp validate_alias_not_mailbox(changeset) do
    alias_email = get_field(changeset, :alias_email)

    if alias_email do
      # Check if this email is already used as a mailbox (case-insensitive)
      query =
        from(m in Elektrine.Email.Mailbox,
          where: fragment("lower(?)", m.email) == ^String.downcase(alias_email),
          limit: 1
        )

      case Elektrine.Repo.one(query) do
        nil ->
          # Also check if this email would conflict with existing usernames
          validate_alias_not_username(changeset, alias_email)

        _mailbox ->
          add_error(changeset, :alias_email, "this email address is already in use as a mailbox")
      end
    else
      changeset
    end
  end

  defp validate_alias_not_username(changeset, alias_email) do
    # Extract local part from email (before @)
    case String.split(alias_email, "@") do
      [local_part, domain] ->
        allowed_domains = ["elektrine.com", "z.org"]

        # Only check for username conflicts on our domains
        if String.downcase(domain) in allowed_domains do
          # Check if local part matches any existing username (case-insensitive)
          query =
            from(u in Elektrine.Accounts.User,
              where: fragment("lower(?)", u.username) == ^String.downcase(local_part),
              limit: 1
            )

          case Elektrine.Repo.one(query) do
            nil ->
              changeset

            _user ->
              add_error(changeset, :alias_email, "this alias conflicts with an existing username")
          end
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_optional_target_email(changeset) do
    target_email = get_field(changeset, :target_email)

    if target_email && String.trim(target_email) != "" do
      validate_format(changeset, :target_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
        message: "must be a valid email format"
      )
    else
      changeset
    end
  end

  defp validate_alias_not_target(changeset) do
    alias_email = get_field(changeset, :alias_email)
    target_email = get_field(changeset, :target_email)

    if alias_email && target_email && String.trim(target_email) != "" &&
         alias_email == target_email do
      add_error(changeset, :target_email, "cannot be the same as the alias email")
    else
      changeset
    end
  end

  defp validate_alias_limit(changeset) do
    user_id = get_field(changeset, :user_id)

    if user_id do
      # Check if user is an admin - admins have unlimited aliases
      user = Elektrine.Repo.get(Elektrine.Accounts.User, user_id)

      if user && user.is_admin do
        # Admin users have no alias limit
        changeset
      else
        # Check if this is a new alias (no ID) or an existing one being updated
        alias_id = get_field(changeset, :id)

        # Count existing aliases for this user, excluding the current one if updating
        existing_count =
          if alias_id do
            Elektrine.Repo.aggregate(
              from(a in Elektrine.Email.Alias,
                where: a.user_id == ^user_id and a.id != ^alias_id
              ),
              :count
            )
          else
            Elektrine.Repo.aggregate(
              from(a in Elektrine.Email.Alias, where: a.user_id == ^user_id),
              :count
            )
          end

        if existing_count >= 15 do
          add_error(changeset, :alias_email, "you can only have up to 15 aliases")
        else
          changeset
        end
      end
    else
      changeset
    end
  end

  defp validate_one_alias_per_domain(changeset) do
    # Per-domain restrictions removed - users can now have up to 4 aliases total
    # across any combination of domains
    changeset
  end

  defp validate_not_reserved_address(changeset) do
    alias_email = get_field(changeset, :alias_email)
    user_id = get_field(changeset, :user_id)

    if alias_email && user_id do
      # Check if user is an admin - admins can create reserved aliases
      user = Elektrine.Repo.get(Elektrine.Accounts.User, user_id)

      if user && user.is_admin do
        # Admin users can create aliases with reserved addresses
        changeset
      else
        # List of reserved email addresses that shouldn't be aliased by regular users
        reserved_addresses = [
          "admin@elektrine.com",
          "admin@z.org",
          "administrator@elektrine.com",
          "administrator@z.org",
          "support@elektrine.com",
          "support@z.org",
          "noreply@elektrine.com",
          "noreply@z.org",
          "no-reply@elektrine.com",
          "no-reply@z.org",
          "postmaster@elektrine.com",
          "postmaster@z.org",
          "hostmaster@elektrine.com",
          "hostmaster@z.org",
          "webmaster@elektrine.com",
          "webmaster@z.org",
          "abuse@elektrine.com",
          "abuse@z.org",
          "security@elektrine.com",
          "security@z.org",
          "help@elektrine.com",
          "help@z.org",
          "info@elektrine.com",
          "info@z.org",
          "contact@elektrine.com",
          "contact@z.org",
          "mail@elektrine.com",
          "mail@z.org",
          "email@elektrine.com",
          "email@z.org",
          # ActivityPub endpoints (critical - would break federation)
          "inbox@elektrine.com",
          "inbox@z.org",
          "outbox@elektrine.com",
          "outbox@z.org",
          "followers@elektrine.com",
          "followers@z.org",
          "following@elektrine.com",
          "following@z.org",
          "actor@elektrine.com",
          "actor@z.org",
          "users@elektrine.com",
          "users@z.org",
          "activities@elektrine.com",
          "activities@z.org",
          "relay@elektrine.com",
          "relay@z.org",
          "ap@elektrine.com",
          "ap@z.org"
        ]

        if String.downcase(alias_email) in reserved_addresses do
          add_error(
            changeset,
            :alias_email,
            "this email address is reserved and cannot be used as an alias"
          )
        else
          changeset
        end
      end
    else
      changeset
    end
  end

  defp normalize_alias_email(changeset) do
    case get_field(changeset, :alias_email) do
      nil ->
        changeset

      email ->
        # Normalize email to lowercase
        normalized = String.downcase(email)
        put_change(changeset, :alias_email, normalized)
    end
  end

  defp validate_alias_local_part(changeset) do
    alias_email = get_field(changeset, :alias_email)

    if alias_email do
      case String.split(alias_email, "@") do
        [local_part, _domain] ->
          cond do
            # Check minimum length (4 characters minimum)
            String.length(local_part) < 4 ->
              add_error(
                changeset,
                :alias_email,
                "must have at least 4 characters before the @ symbol"
              )

            # Check maximum length (30 characters maximum, same as usernames)
            String.length(local_part) > 30 ->
              add_error(
                changeset,
                :alias_email,
                "email address can have at most 30 characters before the @ symbol"
              )

            # Apply same validation as usernames - only alphanumeric
            not String.match?(local_part, ~r/^[a-zA-Z0-9]+$/) ->
              add_error(
                changeset,
                :alias_email,
                "email address can only contain letters and numbers before the @ symbol"
              )

            true ->
              changeset
          end

        _ ->
          # Invalid email format, will be caught by format validation
          changeset
      end
    else
      changeset
    end
  end

  # Recursive forwarding chain detection to prevent cycles
  defp validate_no_forwarding_loops(changeset) do
    alias_email = get_field(changeset, :alias_email)
    target_email = get_field(changeset, :target_email)

    if alias_email && target_email && String.trim(target_email) != "" do
      case detect_forwarding_loop(target_email, alias_email, [], 10) do
        :loop_detected ->
          add_error(
            changeset,
            :target_email,
            "forwarding loop detected - this would create an infinite forwarding cycle"
          )

        :max_depth_reached ->
          add_error(
            changeset,
            :target_email,
            "forwarding chain too deep - maximum 10 hops allowed"
          )

        :safe ->
          changeset
      end
    else
      changeset
    end
  end

  # Recursively trace forwarding chain to detect loops
  defp detect_forwarding_loop(_target, _original, _visited, depth) when depth <= 0 do
    :max_depth_reached
  end

  defp detect_forwarding_loop(target, original, visited, depth) do
    target = String.downcase(String.trim(target))
    original = String.downcase(String.trim(original))

    cond do
      # Direct loop: target points back to original
      target == original ->
        :loop_detected

      # Visited this email before in the chain
      target in visited ->
        :loop_detected

      # Check if target is an alias that forwards elsewhere
      true ->
        case Elektrine.Repo.get_by(Elektrine.Email.Alias, alias_email: target) do
          %Elektrine.Email.Alias{target_email: next_target, enabled: true}
          when is_binary(next_target) and next_target != "" ->
            # This target is an alias that forwards to another address
            # Continue tracing the chain
            detect_forwarding_loop(
              next_target,
              original,
              [target | visited],
              depth - 1
            )

          _ ->
            # Target is not an alias or doesn't forward - chain ends safely
            :safe
        end
    end
  end
end
