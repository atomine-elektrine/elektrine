defmodule Elektrine.PasswordManager.VaultSettings do
  @moduledoc """
  Schema for per-user vault setup metadata.

  `encrypted_verifier` is a client-encrypted payload used to verify passphrase
  correctness locally in the browser.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Accounts.User

  schema "password_vault_settings" do
    field :encrypted_verifier, :map

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating/updating vault setup metadata.
  """
  def setup_changeset(settings, attrs) do
    settings
    |> cast(attrs, [:encrypted_verifier, :user_id])
    |> validate_required([:encrypted_verifier, :user_id])
    |> validate_encrypted_payload(:encrypted_verifier)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end

  defp validate_encrypted_payload(changeset, field) do
    case get_field(changeset, field) do
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
end
