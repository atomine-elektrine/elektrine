defmodule Elektrine.Profiles.CustomDomain do
  @moduledoc """
  Schema for user-managed custom profile domains.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending verified)
  @domain_regex ~r/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/

  schema "profile_custom_domains" do
    field :domain, :string
    field :verification_token, :string
    field :status, :string, default: "pending"
    field :verified_at, :utc_datetime
    field :last_checked_at, :utc_datetime
    field :last_error, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [
      :domain,
      :verification_token,
      :status,
      :verified_at,
      :last_checked_at,
      :last_error,
      :user_id
    ])
    |> update_change(:domain, &normalize_domain/1)
    |> validate_required([:domain, :verification_token, :status, :user_id])
    |> validate_length(:domain, max: 253)
    |> validate_length(:verification_token, max: 255)
    |> validate_length(:last_error, max: 255)
    |> validate_format(:domain, @domain_regex, message: "must be a valid domain name")
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:domain, &validate_profile_domain/2)
    |> unique_constraint(:domain,
      name: :profile_custom_domains_domain_ci_unique,
      message: "is already claimed"
    )
    |> foreign_key_constraint(:user_id)
  end

  defp validate_profile_domain(:domain, domain) when is_binary(domain) do
    cond do
      reserved_profile_edge_domain?(domain) ->
        [domain: "is reserved for profile routing"]

      String.starts_with?(domain, "www.") ->
        [domain: "must be the root domain without www"]

      domain in Elektrine.Domains.supported_email_domains() ->
        [domain: "is already managed by the system"]

      not is_nil(Elektrine.Domains.profile_base_domain_for_host(domain)) ->
        [domain: "conflicts with an existing profile host"]

      true ->
        []
    end
  end

  defp validate_profile_domain(_field, _value), do: []

  defp reserved_profile_edge_domain?(domain) do
    edge_target = Elektrine.Domains.profile_custom_domain_edge_target()

    is_binary(edge_target) and domain in [edge_target, "www.#{edge_target}"]
  end

  defp normalize_domain(nil), do: nil

  defp normalize_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.trim_leading(".")
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp normalize_domain(domain), do: domain
end
