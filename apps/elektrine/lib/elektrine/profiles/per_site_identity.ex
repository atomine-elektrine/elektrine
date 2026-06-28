defmodule Elektrine.Profiles.PerSiteIdentity do
  @moduledoc """
  A per-site domain identity derived from a user's OwnRoot.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.OwnRoot

  @site_key_regex ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/
  @domain_regex ~r/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/

  schema "profile_per_site_identities" do
    field :site_key, :string
    field :base_domain, :string
    field :domain, :string
    field :subject, :string
    field :did, :string
    field :email_alias, :string
    field :display_name, :string
    field :avatar, :string
    field :claims, :map, default: %{}
    field :enabled, :boolean, default: true

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :site_key,
      :base_domain,
      :display_name,
      :avatar,
      :claims,
      :enabled,
      :user_id
    ])
    |> normalize_change(:site_key)
    |> normalize_change(:base_domain)
    |> normalize_claims()
    |> validate_required([:site_key, :base_domain, :user_id])
    |> validate_format(:site_key, @site_key_regex,
      message: "must use lowercase letters, numbers, or hyphens"
    )
    |> validate_format(:base_domain, @domain_regex, message: "must be a valid domain name")
    |> validate_length(:site_key, max: 63)
    |> validate_length(:base_domain, max: 253)
    |> validate_length(:domain, max: 253)
    |> validate_length(:subject, max: 255)
    |> validate_length(:did, max: 255)
    |> validate_length(:email_alias, max: 255)
    |> validate_length(:display_name, max: 120)
    |> validate_length(:avatar, max: 500)
    |> put_derived_fields()
    |> unique_constraint(:site_key,
      name: :profile_per_site_identities_user_base_site_unique,
      message: "already exists for that domain"
    )
    |> foreign_key_constraint(:user_id)
  end

  defp normalize_change(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.trim_leading(".")
        |> String.trim_trailing(".")
        |> String.downcase()

      value ->
        value
    end)
  end

  defp normalize_claims(changeset) do
    case get_field(changeset, :claims) do
      nil -> put_change(changeset, :claims, %{})
      claims when is_map(claims) -> changeset
      _ -> add_error(changeset, :claims, "must be an object")
    end
  end

  defp put_derived_fields(changeset) do
    site_key = get_field(changeset, :site_key)
    base_domain = get_field(changeset, :base_domain)

    if valid_string?(site_key) and valid_string?(base_domain) do
      domain = "#{site_key}.#{base_domain}"

      changeset
      |> put_change(:domain, domain)
      |> put_change(:subject, OwnRoot.subject(domain))
      |> put_change(:did, OwnRoot.did_for_domain(domain))
      |> put_change(:email_alias, "#{site_key}@#{base_domain}")
    else
      changeset
    end
  end

  defp valid_string?(value), do: is_binary(value) and String.trim(value) != ""
end
