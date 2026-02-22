defmodule Elektrine.PasswordManager do
  @moduledoc "Password vault context.\n\nEntries are encrypted at rest per user and only decrypted on demand.\n"
  import Ecto.Query, warn: false
  alias Elektrine.Encryption
  alias Elektrine.PasswordManager.VaultEntry
  alias Elektrine.Repo
  @doc "Lists vault entries for a user.\n\nOnly non-sensitive fields are selected.\n"
  def list_entries(user_id) when is_integer(user_id) do
    VaultEntry
    |> where([entry], entry.user_id == ^user_id)
    |> order_by([entry], desc: entry.inserted_at)
    |> select([entry], %{
      id: entry.id,
      title: entry.title,
      login_username: entry.login_username,
      website: entry.website,
      inserted_at: entry.inserted_at
    })
    |> Repo.all()
  end

  @doc "Creates a vault entry for a user.\n"
  def create_entry(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    attrs = attrs |> normalize_params() |> Map.put("user_id", user_id)
    form_changeset = VaultEntry.form_changeset(%VaultEntry{}, attrs)

    if form_changeset.valid? do
      form_data = Ecto.Changeset.apply_changes(form_changeset)
      encrypted_password = Encryption.encrypt(form_data.password, user_id)
      encrypted_notes = maybe_encrypt(form_data.notes, user_id)

      %VaultEntry{}
      |> VaultEntry.create_changeset(%{
        user_id: user_id,
        title: form_data.title,
        login_username: form_data.login_username,
        website: form_data.website,
        encrypted_password: encrypted_password,
        encrypted_notes: encrypted_notes
      })
      |> Repo.insert()
    else
      {:error, form_changeset}
    end
  end

  @doc "Gets and decrypts a single vault entry for a user.\n"
  def get_entry(user_id, entry_id) when is_integer(user_id) and is_integer(entry_id) do
    case Repo.get_by(VaultEntry, id: entry_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      entry ->
        with {:ok, password} <- safe_decrypt(entry.encrypted_password, user_id),
             {:ok, notes} <- maybe_decrypt(entry.encrypted_notes, user_id) do
          {:ok, %{entry | password: password, notes: notes}}
        else
          {:error, _reason} -> {:error, :decryption_failed}
        end
    end
  end

  @doc "Deletes a vault entry for a user.\n"
  def delete_entry(user_id, entry_id) when is_integer(user_id) and is_integer(entry_id) do
    case Repo.get_by(VaultEntry, id: entry_id, user_id: user_id) do
      nil -> {:error, :not_found}
      entry -> Repo.delete(entry)
    end
  end

  defp maybe_encrypt(nil, _user_id) do
    nil
  end

  defp maybe_encrypt(notes, user_id) do
    Encryption.encrypt(notes, user_id)
  end

  defp maybe_decrypt(nil, _user_id) do
    {:ok, nil}
  end

  defp maybe_decrypt(encrypted_notes, user_id) do
    safe_decrypt(encrypted_notes, user_id)
  end

  defp safe_decrypt(encrypted_data, user_id) when is_map(encrypted_data) do
    Encryption.decrypt(encrypted_data, user_id)
  rescue
    ArgumentError -> {:error, :decryption_failed}
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
end
