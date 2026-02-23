defmodule Elektrine.PasswordManager.VaultEntry do
  @moduledoc """
  Schema for encrypted password vault entries.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Accounts.User

  schema "password_vault_entries" do
    field :title, :string
    field :login_username, :string
    field :website, :string
    field :encrypted_password, :map
    field :encrypted_notes, :map

    # Virtual fields used when revealing decrypted entry data.
    field :password, :string, virtual: true
    field :notes, :string, virtual: true

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for validating non-sensitive form fields.
  """
  def form_changeset(vault_entry, attrs) do
    vault_entry
    |> cast(attrs, [:title, :login_username, :website, :user_id])
    |> normalize_string(:title)
    |> normalize_string(:login_username)
    |> normalize_string(:website)
    |> empty_to_nil(:login_username)
    |> empty_to_nil(:website)
    |> validate_required([:title, :user_id])
    |> validate_length(:title, max: 120)
    |> validate_length(:login_username, max: 255)
    |> validate_length(:website, max: 255)
    |> validate_website()
  end

  @doc """
  Changeset for persisting encrypted vault entries.
  """
  def create_changeset(vault_entry, attrs) do
    vault_entry
    |> cast(attrs, [
      :title,
      :login_username,
      :website,
      :encrypted_password,
      :encrypted_notes,
      :user_id
    ])
    |> normalize_string(:title)
    |> normalize_string(:login_username)
    |> normalize_string(:website)
    |> empty_to_nil(:login_username)
    |> empty_to_nil(:website)
    |> validate_required([:title, :encrypted_password, :user_id])
    |> validate_length(:title, max: 120)
    |> validate_length(:login_username, max: 255)
    |> validate_length(:website, max: 255)
    |> validate_encrypted_payload(:encrypted_password, required: true)
    |> validate_encrypted_payload(:encrypted_notes, required: false)
    |> validate_website()
    |> foreign_key_constraint(:user_id)
  end

  defp validate_website(changeset) do
    case get_field(changeset, :website) do
      nil ->
        changeset

      website ->
        if valid_website?(website) do
          changeset
        else
          add_error(changeset, :website, "must start with http:// or https://")
        end
    end
  end

  defp valid_website?(website) when is_binary(website) do
    uri = URI.parse(website)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp normalize_string(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end

  defp validate_encrypted_payload(changeset, field, opts) do
    required? = Keyword.get(opts, :required, false)

    case get_field(changeset, field) do
      nil ->
        if required? do
          add_error(changeset, field, "can't be blank")
        else
          changeset
        end

      payload when is_map(payload) ->
        if valid_client_payload?(payload) do
          changeset
        else
          add_error(changeset, field, "must be a valid client-encrypted payload")
        end

      _ ->
        add_error(changeset, field, "must be a valid client-encrypted payload")
    end
  end

  defp valid_client_payload?(payload) do
    version = payload_value(payload, "version", :version)
    algorithm = payload_value(payload, "algorithm", :algorithm)
    kdf = payload_value(payload, "kdf", :kdf)
    iterations = payload_value(payload, "iterations", :iterations)
    salt = payload_value(payload, "salt", :salt)
    iv = payload_value(payload, "iv", :iv)
    ciphertext = payload_value(payload, "ciphertext", :ciphertext)

    valid_version?(version) and algorithm == "AES-GCM" and kdf == "PBKDF2-SHA256" and
      is_integer(iterations) and iterations >= 100_000 and iterations <= 1_000_000 and
      valid_base64_bytes?(salt, min_size: 16) and valid_base64_bytes?(iv, exact_size: 12) and
      valid_base64_bytes?(ciphertext, min_size: 1)
  end

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

  defp empty_to_nil(changeset, field) do
    case get_change(changeset, field) do
      "" -> put_change(changeset, field, nil)
      _ -> changeset
    end
  end
end
