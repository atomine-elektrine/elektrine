defmodule Elektrine.Nerve do
  @moduledoc """
  Password nerve context.

  Nerve secrets are expected to be encrypted on the client and are never decrypted
  server-side. The server stores and returns ciphertext envelopes only.
  """
  import Ecto.Query, warn: false
  alias Elektrine.Nerve.{NerveEntry, NerveSettings}
  alias Elektrine.Repo

  @doc """
  Creates or updates per-user Nerve setup metadata.
  """
  def setup_nerve(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    attrs = attrs |> normalize_params() |> Map.put("user_id", user_id)
    settings = get_nerve_settings(user_id) || %NerveSettings{}

    settings
    |> NerveSettings.setup_changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Returns the user's Nerve setup metadata, or nil."
  def get_nerve_settings(user_id) when is_integer(user_id) do
    Repo.get_by(NerveSettings, user_id: user_id)
  end

  @doc "Whether the user has Nerve setup metadata."
  def nerve_configured?(user_id) when is_integer(user_id) do
    Repo.exists?(from(settings in NerveSettings, where: settings.user_id == ^user_id))
  end

  @doc """
  Lists nerve entries for a user.

  By default only non-sensitive fields are selected.
  """
  def list_entries(user_id, opts \\ []) when is_integer(user_id) and is_list(opts) do
    include_secrets? = Keyword.get(opts, :include_secrets, false)

    NerveEntry
    |> where([entry], entry.user_id == ^user_id)
    |> order_by([entry], desc: entry.inserted_at)
    |> select([entry], map(entry, ^entry_fields(include_secrets?)))
    |> Repo.all()
  end

  @doc "Creates a nerve entry for a user.\n"
  def create_entry(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    attrs = attrs |> normalize_params() |> Map.put("user_id", user_id)

    %NerveEntry{}
    |> NerveEntry.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a nerve entry for a user.
  """
  def update_entry(user_id, entry_id, attrs)
      when is_integer(user_id) and is_integer(entry_id) and is_map(attrs) do
    attrs = attrs |> normalize_params() |> Map.put("user_id", user_id)

    case Repo.get_by(NerveEntry, id: entry_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      entry ->
        entry
        |> NerveEntry.create_changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Gets a single nerve entry ciphertext payload for a user.
  """
  def get_entry_ciphertext(user_id, entry_id) when is_integer(user_id) and is_integer(entry_id) do
    case Repo.get_by(NerveEntry, id: entry_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok, entry}
    end
  end

  @doc "Deletes a nerve entry for a user.\n"
  def delete_entry(user_id, entry_id) when is_integer(user_id) and is_integer(entry_id) do
    case Repo.get_by(NerveEntry, id: entry_id, user_id: user_id) do
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

  defp entry_fields(false),
    do: [:id, :title, :login_username, :website, :encrypted_metadata, :inserted_at]

  defp entry_fields(true) do
    [
      :id,
      :title,
      :login_username,
      :website,
      :encrypted_metadata,
      :inserted_at,
      :encrypted_password,
      :encrypted_notes
    ]
  end
end
