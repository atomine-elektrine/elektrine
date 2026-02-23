defmodule Elektrine.PasswordManager do
  @moduledoc """
  Password vault context.

  Vault secrets are expected to be encrypted on the client and are never decrypted
  server-side. The server stores and returns ciphertext envelopes only.
  """
  import Ecto.Query, warn: false
  alias Elektrine.PasswordManager.VaultEntry
  alias Elektrine.PasswordManager.VaultSettings
  alias Elektrine.Repo

  @doc """
  Returns whether a user has completed vault setup.
  """
  def vault_configured?(user_id) when is_integer(user_id) do
    Repo.exists?(from(settings in VaultSettings, where: settings.user_id == ^user_id))
  end

  @doc """
  Creates or updates vault setup metadata for a user.
  """
  def setup_vault(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    attrs = attrs |> normalize_params() |> Map.put("user_id", user_id)

    case Repo.get_by(VaultSettings, user_id: user_id) do
      nil ->
        %VaultSettings{}
        |> VaultSettings.setup_changeset(attrs)
        |> Repo.insert()

      settings ->
        settings
        |> VaultSettings.setup_changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Gets a user's vault setup metadata.
  """
  def get_vault_settings(user_id) when is_integer(user_id) do
    Repo.get_by(VaultSettings, user_id: user_id)
  end

  @doc """
  Lists vault entries for a user.

  By default only non-sensitive fields are selected.
  """
  def list_entries(user_id, opts \\ []) when is_integer(user_id) and is_list(opts) do
    include_secrets? = Keyword.get(opts, :include_secrets, false)

    VaultEntry
    |> where([entry], entry.user_id == ^user_id)
    |> order_by([entry], desc: entry.inserted_at)
    |> select([entry], map(entry, ^entry_fields(include_secrets?)))
    |> Repo.all()
  end

  @doc "Creates a vault entry for a user.\n"
  def create_entry(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    attrs = attrs |> normalize_params() |> Map.put("user_id", user_id)

    if vault_configured?(user_id) do
      %VaultEntry{}
      |> VaultEntry.create_changeset(attrs)
      |> Repo.insert()
    else
      {:error, :vault_not_configured}
    end
  end

  @doc """
  Gets a single vault entry ciphertext payload for a user.
  """
  def get_entry_ciphertext(user_id, entry_id) when is_integer(user_id) and is_integer(entry_id) do
    case Repo.get_by(VaultEntry, id: entry_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok, entry}
    end
  end

  @doc "Deletes a vault entry for a user.\n"
  def delete_entry(user_id, entry_id) when is_integer(user_id) and is_integer(entry_id) do
    case Repo.get_by(VaultEntry, id: entry_id, user_id: user_id) do
      nil -> {:error, :not_found}
      entry -> Repo.delete(entry)
    end
  end

  defp normalize_params(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc -> Map.put(acc, normalize_key(key), value) end)
  end

  defp normalize_key(key) when is_atom(key) do
    Atom.to_string(key)
  end

  defp normalize_key(key) do
    key
  end

  defp entry_fields(false), do: [:id, :title, :login_username, :website, :inserted_at]

  defp entry_fields(true) do
    [:id, :title, :login_username, :website, :inserted_at, :encrypted_password, :encrypted_notes]
  end
end
