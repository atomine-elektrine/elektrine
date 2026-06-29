defmodule Elektrine.Nerve do
  @moduledoc """
  Password nerve context.

  Nerve secrets are expected to be encrypted on the client and are never decrypted
  server-side. The server stores and returns ciphertext envelopes only.
  """
  import Ecto.Query, warn: false
  alias Elektrine.Nerve.NerveEntry
  alias Elektrine.Repo

  @doc """
  Deletes all of a user's encrypted Nerve entries.

  Nerve entries are encrypted under the master key; this is the "start over"
  path when that data is no longer wanted or recoverable.
  """
  def delete_nerve(user_id) when is_integer(user_id) do
    {deleted_entries, _} =
      from(entry in NerveEntry, where: entry.user_id == ^user_id)
      |> Repo.delete_all()

    {:ok, %{deleted_entries: deleted_entries}}
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
