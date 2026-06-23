defmodule Elektrine.Profiles.PerSiteIdentities do
  @moduledoc """
  Context functions for per-site portable domain identities.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.Domains
  alias Elektrine.Profiles
  alias Elektrine.Profiles.PerSiteIdentity
  alias Elektrine.Repo

  def list_user_per_site_identities(%User{id: user_id}),
    do: list_user_per_site_identities(user_id)

  def list_user_per_site_identities(user_id) when is_integer(user_id) do
    PerSiteIdentity
    |> where(user_id: ^user_id)
    |> order_by([i], asc: i.base_domain, asc: i.site_key)
    |> Repo.all()
  end

  def list_user_per_site_identities(_), do: []

  def get_per_site_identity(id, user_id) when is_integer(id) and is_integer(user_id) do
    PerSiteIdentity
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  def get_per_site_identity(_, _), do: nil

  def create_per_site_identity(%User{id: user_id} = user, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- validate_base_domain(user, attrs["base_domain"] || attrs[:base_domain]) do
      %PerSiteIdentity{}
      |> PerSiteIdentity.changeset(put_user_id(attrs, user_id))
      |> Repo.insert()
    end
  end

  def update_per_site_identity(%PerSiteIdentity{} = identity, attrs) when is_map(attrs) do
    identity
    |> PerSiteIdentity.changeset(attrs)
    |> Repo.update()
  end

  def delete_per_site_identity(%PerSiteIdentity{} = identity), do: Repo.delete(identity)

  def available_base_domains(%User{} = user) do
    [built_in_domain(user) | Enum.map(Profiles.verified_domains_for_user(user), & &1.domain)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def built_in_domain(%User{} = user) do
    handle = user.handle || user.username

    if is_binary(handle) and String.trim(handle) != "" do
      "#{String.trim(handle)}.#{Domains.default_profile_domain()}" |> String.downcase()
    end
  end

  defp validate_base_domain(user, base_domain) when is_binary(base_domain) do
    normalized =
      base_domain
      |> String.trim()
      |> String.trim_leading(".")
      |> String.trim_trailing(".")
      |> String.downcase()

    if normalized in available_base_domains(user) do
      :ok
    else
      {:error, :invalid_base_domain}
    end
  end

  defp validate_base_domain(_, _), do: {:error, :invalid_base_domain}

  defp normalize_attrs(attrs) do
    attrs
    |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
    |> Map.new()
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp put_user_id(attrs, user_id) do
    if Enum.any?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, "user_id", user_id)
    else
      Map.put(attrs, :user_id, user_id)
    end
  end
end
