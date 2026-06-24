defmodule Elektrine.Accounts.AppPassword do
  @moduledoc """
  Schema for app-specific passwords that bypass 2FA for email clients.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @current_hash_prefix "v3$argon2id$"
  @hmac_hash_prefix "v2$hmac-sha256$"

  schema "app_passwords" do
    field :name, :string
    field :token_hash, :string
    field :last_used_at, :utc_datetime
    field :last_used_ip, :string
    field :expires_at, :utc_datetime

    # Virtual field for the raw token (only available on creation)
    field :token, :string, virtual: true

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(app_password, attrs) do
    app_password
    |> cast(attrs, [:name, :token_hash, :user_id, :expires_at])
    |> validate_required([:name, :token_hash, :user_id])
    |> validate_length(:name, max: 100)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Creates a changeset for a new app password with a generated token.
  """
  def create_changeset(attrs) do
    # Generate a secure random token
    token = generate_token()
    token_hash = hash_token(token)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:name, :user_id, :expires_at])
      |> validate_required([:name, :user_id])
      |> validate_length(:name, max: 100)
      |> put_change(:token_hash, token_hash)

    # Attach the raw token (WITH dashes) to the struct for display to the user
    # This is the only time the raw token is available
    %{changeset | changes: Map.put(changeset.changes, :token, token)}
  end

  @doc """
  Updates last used information for an app password.
  """
  def update_last_used(app_password, ip_address \\ nil) do
    app_password
    |> change(%{
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_used_ip: ip_address
    })
  end

  @doc """
  Generates a secure random token for app password.
  Format: xxxx-xxxx-xxxx-xxxx-xxxx-xxxx-xxxx-xxxx (32 characters)
  """
  def generate_token do
    :crypto.strong_rand_bytes(20)
    |> Base.encode32(case: :lower, padding: false)
    |> format_token()
  end

  defp format_token(token) do
    token
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  @doc """
  Hashes a token for secure storage.
  """
  def hash_token(token) do
    @current_hash_prefix <> Argon2.hash_pwd_salt(normalize_current_token(token))
  end

  @doc "Returns deterministic token hashes that can authenticate pre-v3 tokens.

  Argon2id app-password hashes are salted, so they must be verified row-by-row
  with `verify_token/2` instead of looked up directly by hash.
  "
  def candidate_hashes(token) do
    clean_token = normalize_current_token(token)
    legacy_token = normalize_legacy_token(token)

    hmac_hashes([clean_token, legacy_token])
    |> Enum.uniq()
  end

  defp normalize_current_token(token) when is_binary(token) do
    token
    |> String.replace(~r/[^a-z2-7]/i, "")
    |> String.downcase()
  end

  defp normalize_current_token(_token), do: ""

  defp normalize_legacy_token(token) when is_binary(token) do
    String.trim(token)
  end

  defp normalize_legacy_token(_token), do: ""

  defp hmac_hashes(tokens) do
    case app_password_pepper() do
      pepper when is_binary(pepper) ->
        Enum.map(tokens, fn token -> @hmac_hash_prefix <> hmac_token(token, pepper) end)

      nil ->
        []
    end
  end

  defp hmac_token(token, pepper) do
    :crypto.mac(:hmac, :sha256, pepper, token)
    |> Base.url_encode64(padding: false)
  end

  defp app_password_pepper do
    Application.get_env(:elektrine, :app_password_pepper) ||
      Application.get_env(:elektrine, :encryption_master_secret) ||
      get_in(Application.get_env(:elektrine, ElektrineWeb.Endpoint, []), [:secret_key_base])
  end

  @doc """
  Verifies if a given token matches the stored hash.
  """
  def verify_token(token, token_hash) do
    cond do
      argon2_hash?(token_hash) ->
        verify_argon2_token(token, token_hash)

      hmac_hash?(token_hash) ->
        Enum.any?(candidate_hashes(token), &secure_compare(&1, token_hash))

      true ->
        false
    end
  end

  @doc "Returns the stored app-password hash version for diagnostics."
  def hash_version(token_hash) when is_binary(token_hash) do
    cond do
      String.starts_with?(token_hash, @current_hash_prefix) -> :v3_argon2id
      argon2_hash?(token_hash) -> :argon2id
      hmac_hash?(token_hash) -> :v2_hmac
      true -> :unknown
    end
  end

  def hash_version(_token_hash), do: :unknown

  defp argon2_hash?(token_hash) when is_binary(token_hash),
    do: not is_nil(argon2_hash_body(token_hash))

  defp argon2_hash?(_), do: false

  defp hmac_hash?(token_hash) when is_binary(token_hash),
    do: String.starts_with?(token_hash, @hmac_hash_prefix)

  defp hmac_hash?(_), do: false

  defp verify_argon2_token(token, token_hash) do
    case argon2_hash_body(token_hash) do
      nil ->
        false

      argon2_hash ->
        token
        |> argon2_token_candidates()
        |> Enum.any?(&verify_argon2_candidate(&1, argon2_hash))
    end
  end

  defp argon2_hash_body(@current_hash_prefix <> argon2_hash),
    do: normalize_argon2_hash_body(argon2_hash)

  defp argon2_hash_body("$argon2id$" <> _ = argon2_hash), do: argon2_hash
  defp argon2_hash_body(_), do: nil

  defp normalize_argon2_hash_body("$argon2id$" <> _ = argon2_hash), do: argon2_hash
  defp normalize_argon2_hash_body("argon2id$" <> _ = argon2_hash), do: "$" <> argon2_hash
  defp normalize_argon2_hash_body(_), do: nil

  defp argon2_token_candidates(token) when is_binary(token) do
    trimmed = String.trim(token)

    [
      normalize_current_token(token),
      trimmed,
      String.downcase(trimmed)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp argon2_token_candidates(_), do: []

  defp verify_argon2_candidate(candidate, argon2_hash) do
    Argon2.verify_pass(candidate, argon2_hash)
  rescue
    _ -> false
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false
end
