defmodule Elektrine.Vault do
  @moduledoc """
  Encrypted data vault context.

  A user's password derives a key that wraps a single Master Data Key
  (MDK); per-feature keys (Nerve, Kairo, email private storage) are derived from
  the MDK in the browser via HKDF. The server only ever stores and returns the
  wrapped MDK blobs - it never sees the passphrase, the recovery code, or the
  MDK. Unlock, rotation, and recovery all happen client-side.
  """
  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  alias Elektrine.Vault.MasterKey

  @doc "Whether the user has set up encrypted data."
  def configured?(%User{id: user_id}), do: configured?(user_id)

  def configured?(user_id) when is_integer(user_id) do
    Repo.exists?(from(mk in MasterKey, where: mk.user_id == ^user_id))
  end

  @doc "Returns the user's master key record (with the wrapped blobs), or nil."
  def get(%User{id: user_id}), do: get(user_id)

  def get(user_id) when is_integer(user_id) do
    Repo.get_by(MasterKey, user_id: user_id)
  end

  @doc """
  Creates the user's master key for the first time.

  Fails if one already exists - replacing it would orphan everything encrypted
  under the old MDK. Use `rotate/2` to change the passphrase or `reset/1` to
  deliberately discard all encrypted data.
  """
  def setup(%User{id: user_id}, attrs), do: setup(user_id, attrs)

  def setup(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    if configured?(user_id) do
      {:error, :already_configured}
    else
      %MasterKey{}
      |> MasterKey.setup_changeset(normalize(attrs, user_id))
      |> Repo.insert()
    end
  end

  @doc """
  Re-wraps the MDK after a passphrase change or recovery.

  The client unwraps the MDK (with the old passphrase or the recovery code),
  re-wraps it under the new passphrase, and sends the new blobs - the underlying
  MDK is unchanged, so no encrypted data needs to be touched.
  """
  def rotate(%User{id: user_id}, attrs), do: rotate(user_id, attrs)

  def rotate(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    case get(user_id) do
      nil ->
        {:error, :not_configured}

      master_key ->
        master_key |> MasterKey.rewrap_changeset(normalize(attrs, user_id)) |> Repo.update()
    end
  end

  @doc """
  Deletes the user's master key. This permanently loses access to everything
  encrypted under it; intended only for a deliberate "start over" / lost-secret
  reset by the user.
  """
  def reset(%User{id: user_id}), do: reset(user_id)

  def reset(user_id) when is_integer(user_id) do
    {count, _} = from(mk in MasterKey, where: mk.user_id == ^user_id) |> Repo.delete_all()
    {:ok, count > 0}
  end

  defp normalize(attrs, user_id) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("user_id", user_id)
  end
end
