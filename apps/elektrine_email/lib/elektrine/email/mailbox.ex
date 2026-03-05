defmodule Elektrine.Email.Mailbox do
  @moduledoc """
  Schema for email mailboxes supporting configured local domains.
  Handles domain-agnostic username-based email addresses with forwarding capabilities.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "mailboxes" do
    # Legacy field - will be phased out
    field :email, :string
    # Domain-agnostic username
    field :username, :string
    field :forward_to, :string
    field :forward_enabled, :boolean, default: false

    belongs_to :user, Elektrine.Accounts.User
    has_many :messages, Elektrine.Email.Message

    timestamps(type: :utc_datetime)
  end

  @doc """
  Gets all primary email addresses for this mailbox.
  Returns all configured local-domain variants for the mailbox username.
  """
  def get_all_emails(%__MODULE__{username: username}) when is_binary(username) do
    Elektrine.Domains.local_addresses_for_username(username)
  end

  def get_all_emails(%__MODULE__{email: email}) when is_binary(email) do
    # Fallback for legacy mailboxes without username field
    case String.split(email, "@", parts: 2) do
      [username, _domain] ->
        Elektrine.Domains.local_addresses_for_username(username)

      _ ->
        [email]
    end
  end

  def get_all_emails(_), do: []

  @doc """
  Checks if an email address belongs to this mailbox (either domain).
  """
  def owns_email?(%__MODULE__{} = mailbox, email_address) when is_binary(email_address) do
    email_address = String.downcase(String.trim(email_address))
    all_emails = get_all_emails(mailbox) |> Enum.map(&String.downcase/1)
    email_address in all_emails
  end

  @doc """
  Creates a changeset for a new mailbox.
  """
  def changeset(mailbox, attrs) do
    mailbox
    |> cast(attrs, [:email, :username, :user_id, :forward_to, :forward_enabled])
    |> validate_length(:email, max: 160)
    |> validate_length(:username, min: 1, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9]+$/, message: "only letters and numbers allowed")
    |> validate_not_reserved_email()
    |> unique_constraint(:email)
    |> unique_constraint(:username)
    |> foreign_key_constraint(:user_id)
    |> validate_forwarding()
  end

  @doc """
  Creates a changeset for updating mailbox forwarding settings.
  """
  def forwarding_changeset(mailbox, attrs) do
    mailbox
    |> cast(attrs, [:forward_to, :forward_enabled])
    |> validate_forwarding()
  end

  @doc """
  Creates a changeset for a new orphaned mailbox (without a user).
  """
  def orphaned_changeset(mailbox, attrs) do
    mailbox
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end

  @doc """
  Creates a domain-agnostic mailbox for a user.
  Uses the configured primary email domain as storage but keeps username for domain-agnostic lookup.
  All configured local-domain addresses will resolve to this same mailbox.
  """
  def create_for_user(user, _domain \\ nil) do
    # Always use configured primary domain for storage, but keep username for domain-agnostic access.
    primary_domain = Elektrine.Domains.primary_email_domain()
    email = "#{user.username}@#{primary_domain}"

    %Elektrine.Email.Mailbox{}
    |> changeset(%{email: email, username: user.username, user_id: user.id})
  end

  # Private helper functions

  defp validate_forwarding(changeset) do
    forward_enabled = get_field(changeset, :forward_enabled)
    forward_to = get_field(changeset, :forward_to)

    cond do
      forward_enabled && (is_nil(forward_to) || String.trim(forward_to) == "") ->
        add_error(changeset, :forward_to, "must be specified when forwarding is enabled")

      forward_to && String.trim(forward_to) != "" ->
        changeset
        |> validate_format(:forward_to, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
          message: "must be a valid email format"
        )
        |> validate_not_self_forwarding()
        |> validate_no_forwarding_loops()

      true ->
        changeset
    end
  end

  defp validate_not_self_forwarding(changeset) do
    email = get_field(changeset, :email)
    username = get_field(changeset, :username)
    forward_to = get_field(changeset, :forward_to)

    if forward_to do
      # Check both email and username@domain variants
      mailbox_addresses =
        if username do
          Elektrine.Domains.local_addresses_for_username(username)
        else
          [email]
        end

      if String.downcase(forward_to) in Enum.map(mailbox_addresses, &String.downcase/1) do
        add_error(changeset, :forward_to, "cannot forward to the same email address")
      else
        changeset
      end
    else
      changeset
    end
  end

  # Recursive forwarding loop detection (checks both aliases and mailboxes)
  defp validate_no_forwarding_loops(changeset) do
    email = get_field(changeset, :email)
    username = get_field(changeset, :username)
    forward_to = get_field(changeset, :forward_to)

    if forward_to && String.trim(forward_to) != "" do
      # Get all addresses for this mailbox
      original_addresses =
        if username do
          Elektrine.Domains.local_addresses_for_username(username)
        else
          [email]
        end

      case detect_mailbox_forwarding_loop(forward_to, original_addresses, [], 10) do
        :loop_detected ->
          add_error(
            changeset,
            :forward_to,
            "forwarding loop detected - this would create an infinite forwarding cycle"
          )

        :max_depth_reached ->
          add_error(
            changeset,
            :forward_to,
            "forwarding chain too deep - maximum 10 hops allowed"
          )

        :safe ->
          changeset
      end
    else
      changeset
    end
  end

  # Recursively trace forwarding chain to detect loops (checks both mailboxes and aliases)
  defp detect_mailbox_forwarding_loop(_target, _originals, _visited, depth) when depth <= 0 do
    :max_depth_reached
  end

  defp detect_mailbox_forwarding_loop(target, originals, visited, depth) do
    target = String.downcase(String.trim(target))
    originals = Enum.map(originals, &String.downcase/1)

    cond do
      # Direct loop: target points back to any original address
      target in originals ->
        :loop_detected

      # Visited this email before in the chain
      target in visited ->
        :loop_detected

      # Check if target is an alias that forwards elsewhere
      true ->
        # First check aliases
        case Elektrine.Repo.get_by(Elektrine.Email.Alias, alias_email: target) do
          %Elektrine.Email.Alias{target_email: next_target, enabled: true}
          when is_binary(next_target) and next_target != "" ->
            # This target is an alias that forwards to another address
            detect_mailbox_forwarding_loop(
              next_target,
              originals,
              [target | visited],
              depth - 1
            )

          _ ->
            # Not an alias, check if it's a mailbox with forwarding
            case Elektrine.Repo.get_by(Elektrine.Email.Mailbox, email: target) do
              %Elektrine.Email.Mailbox{forward_enabled: true, forward_to: next_target}
              when is_binary(next_target) and next_target != "" ->
                # This mailbox forwards to another address
                detect_mailbox_forwarding_loop(
                  next_target,
                  originals,
                  [target | visited],
                  depth - 1
                )

              _ ->
                # Also check by username (domain-agnostic)
                case String.split(target, "@") do
                  [target_username, target_domain] ->
                    if Elektrine.Domains.local_email_domain?(target_domain) do
                      case Elektrine.Repo.get_by(Elektrine.Email.Mailbox,
                             username: target_username
                           ) do
                        %Elektrine.Email.Mailbox{forward_enabled: true, forward_to: next_target}
                        when is_binary(next_target) and next_target != "" ->
                          detect_mailbox_forwarding_loop(
                            next_target,
                            originals,
                            [target | visited],
                            depth - 1
                          )

                        _ ->
                          # Chain ends safely
                          :safe
                      end
                    else
                      # External address - chain ends safely
                      :safe
                    end

                  _ ->
                    # External address or invalid format - chain ends
                    :safe
                end
            end
        end
    end
  end

  defp validate_not_reserved_email(changeset) do
    email = get_field(changeset, :email)
    username = get_field(changeset, :username)

    reserved_addresses = Elektrine.Domains.reserved_addresses()

    # Extract reserved usernames from reserved addresses
    reserved_usernames =
      Elektrine.Domains.reserved_local_parts()

    changeset =
      if email && String.downcase(email) in reserved_addresses do
        add_error(changeset, :email, "this email address is reserved and cannot be used")
      else
        changeset
      end

    if username && String.downcase(username) in reserved_usernames do
      add_error(changeset, :username, "this username is reserved and cannot be used")
    else
      changeset
    end
  end
end
