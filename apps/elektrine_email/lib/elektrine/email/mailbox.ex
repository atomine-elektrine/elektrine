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
    field :private_storage_enabled, :boolean, default: false
    field :private_storage_public_key, :string
    field :private_storage_wrapped_private_key, :map
    field :private_storage_verifier, :map

    belongs_to :user, Elektrine.Accounts.User
    has_many :messages, Elektrine.Email.Message

    timestamps(type: :utc_datetime)
  end

  @doc """
  Gets all primary email addresses for this mailbox.
  Returns all configured local-domain variants for the mailbox username.
  """
  def get_all_emails(%__MODULE__{username: username, user_id: user_id})
      when is_binary(username) do
    mailbox_addresses(username, user_id, nil)
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
  Creates a changeset for browser-managed private mailbox storage settings.
  """
  def private_storage_changeset(mailbox, attrs) do
    mailbox
    |> cast(attrs, [
      :private_storage_enabled,
      :private_storage_public_key,
      :private_storage_wrapped_private_key,
      :private_storage_verifier
    ])
    |> validate_private_storage()
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

  @doc """
  Returns true when mailbox private storage has been configured.
  """
  def private_storage_configured?(%__MODULE__{} = mailbox) do
    Elektrine.Strings.present?(mailbox.private_storage_public_key) and
      is_map(mailbox.private_storage_wrapped_private_key) and
      is_map(mailbox.private_storage_verifier)
  end

  def private_storage_configured?(_mailbox), do: false

  @doc """
  Returns the configured unlock mode for browser-managed private mailbox storage.
  """
  def private_storage_unlock_mode(%__MODULE__{} = mailbox) do
    unlock_mode =
      payload_value(
        mailbox.private_storage_wrapped_private_key || %{},
        "unlock_mode",
        :unlock_mode
      ) ||
        payload_value(mailbox.private_storage_verifier || %{}, "unlock_mode", :unlock_mode)

    if unlock_mode in ["account_password", "separate_passphrase"] do
      unlock_mode
    else
      "separate_passphrase"
    end
  end

  def private_storage_unlock_mode(_mailbox), do: "separate_passphrase"

  def private_storage_account_password?(%__MODULE__{} = mailbox) do
    private_storage_configured?(mailbox) and
      private_storage_unlock_mode(mailbox) == "account_password"
  end

  def private_storage_account_password?(_mailbox), do: false

  # Private helper functions

  defp validate_private_storage(changeset) do
    enabled? = get_field(changeset, :private_storage_enabled)
    public_key = get_field(changeset, :private_storage_public_key)
    wrapped_private_key = get_field(changeset, :private_storage_wrapped_private_key)
    verifier = get_field(changeset, :private_storage_verifier)

    cond do
      enabled? && !valid_public_key?(public_key) ->
        add_error(changeset, :private_storage_public_key, "must be a valid RSA public key")

      enabled? && !valid_wrapped_payload?(wrapped_private_key) ->
        add_error(
          changeset,
          :private_storage_wrapped_private_key,
          "must be a valid wrapped private key payload"
        )

      enabled? && !valid_wrapped_payload?(verifier) ->
        add_error(changeset, :private_storage_verifier, "must be a valid verifier payload")

      true ->
        changeset
    end
  end

  defp valid_public_key?(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, "-----BEGIN PUBLIC KEY-----") do
      case :public_key.pem_decode(trimmed) do
        [entry | _] ->
          _decoded = :public_key.pem_entry_decode(entry)
          true

        _ ->
          false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp valid_public_key?(_value), do: false

  defp valid_wrapped_payload?(payload) when is_map(payload) do
    version = payload_value(payload, "version", :version)
    algorithm = payload_value(payload, "algorithm", :algorithm)
    kdf = payload_value(payload, "kdf", :kdf)
    unlock_mode = payload_value(payload, "unlock_mode", :unlock_mode)
    n = payload_value(payload, "n", :n)
    r = payload_value(payload, "r", :r)
    p = payload_value(payload, "p", :p)
    salt = payload_value(payload, "salt", :salt)
    iv = payload_value(payload, "iv", :iv)
    ciphertext = payload_value(payload, "ciphertext", :ciphertext)

    valid_version?(version) and algorithm == "AES-GCM" and kdf == "scrypt" and
      (is_nil(unlock_mode) or unlock_mode in ["account_password", "separate_passphrase"]) and
      is_integer(n) and n >= 16_384 and is_integer(r) and r >= 8 and is_integer(p) and p >= 1 and
      valid_base64_bytes?(salt, min_size: 16) and valid_base64_bytes?(iv, exact_size: 12) and
      valid_base64_bytes?(ciphertext, min_size: 1)
  end

  defp valid_wrapped_payload?(_payload), do: false

  defp payload_value(payload, string_key, atom_key) do
    Map.get(payload, string_key) || Map.get(payload, atom_key)
  end

  defp valid_version?(version) when is_integer(version), do: version >= 1
  defp valid_version?(version) when is_float(version), do: version >= 1
  defp valid_version?(_version), do: false

  defp valid_base64_bytes?(value, opts) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} ->
        size = byte_size(bytes)
        min_size = Keyword.get(opts, :min_size, 0)
        exact_size = Keyword.get(opts, :exact_size)

        size >= min_size and (is_nil(exact_size) or size == exact_size)

      :error ->
        false
    end
  end

  defp valid_base64_bytes?(_value, _opts), do: false

  defp validate_forwarding(changeset) do
    forward_enabled = get_field(changeset, :forward_enabled)
    forward_to = get_field(changeset, :forward_to)

    cond do
      forward_enabled && not Elektrine.Strings.present?(forward_to) ->
        add_error(changeset, :forward_to, "enter a forwarding address")

      Elektrine.Strings.present?(forward_to) ->
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
    user_id = get_field(changeset, :user_id)
    forward_to = get_field(changeset, :forward_to)

    if forward_to do
      mailbox_addresses = mailbox_addresses(username, user_id, email)

      if String.downcase(forward_to) in Enum.map(mailbox_addresses, &String.downcase/1) do
        add_error(changeset, :forward_to, "choose a different forwarding address")
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
    user_id = get_field(changeset, :user_id)
    forward_to = get_field(changeset, :forward_to)

    if Elektrine.Strings.present?(forward_to) do
      original_addresses = mailbox_addresses(username, user_id, email)

      case detect_mailbox_forwarding_loop(forward_to, original_addresses, [], 10) do
        :loop_detected ->
          add_error(
            changeset,
            :forward_to,
            "this forwarding address would create a loop"
          )

        :max_depth_reached ->
          add_error(
            changeset,
            :forward_to,
            "this forwarding chain is too long"
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
        case Elektrine.Email.Aliases.get_alias_by_email(target) do
          %Elektrine.Email.Alias{target_email: next_target, enabled: true}
          when is_binary(next_target) ->
            if Elektrine.Strings.present?(next_target) do
              detect_mailbox_forwarding_loop(
                next_target,
                originals,
                [target | visited],
                depth - 1
              )
            else
              :ok
            end

          _ ->
            case Elektrine.Email.Mailboxes.get_mailbox_by_email(target) do
              %Elektrine.Email.Mailbox{forward_enabled: true, forward_to: next_target}
              when is_binary(next_target) ->
                if Elektrine.Strings.present?(next_target) do
                  detect_mailbox_forwarding_loop(
                    next_target,
                    originals,
                    [target | visited],
                    depth - 1
                  )
                else
                  :ok
                end

              _ ->
                :safe
            end
        end
    end
  end

  defp mailbox_addresses(username, user_id, fallback_email)

  defp mailbox_addresses(username, user_id, _fallback_email)
       when is_binary(username) and is_integer(user_id) do
    Elektrine.Domains.available_email_domains_for_user(user_id)
    |> Enum.map(&"#{username}@#{&1}")
  end

  defp mailbox_addresses(username, _user_id, _fallback_email) when is_binary(username) do
    Elektrine.Domains.local_addresses_for_username(username)
  end

  defp mailbox_addresses(_username, _user_id, fallback_email) when is_binary(fallback_email) do
    [fallback_email]
  end

  defp mailbox_addresses(_, _, _), do: []

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
