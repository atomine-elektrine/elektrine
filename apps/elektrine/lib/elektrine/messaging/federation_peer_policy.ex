defmodule Elektrine.Messaging.FederationPeerPolicy do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_peer_policies" do
    field :domain, :string
    field :allow_incoming, :boolean
    field :allow_outgoing, :boolean
    field :blocked, :boolean, default: false
    field :reason, :string

    belongs_to :updated_by, Elektrine.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :domain,
      :allow_incoming,
      :allow_outgoing,
      :blocked,
      :reason,
      :updated_by_id
    ])
    |> validate_required([:domain])
    |> update_change(:domain, &normalize_domain/1)
    |> validate_required([:domain])
    |> validate_format(:domain, ~r/^[a-z0-9.-]+$/, message: "must be a valid domain")
    |> validate_length(:domain, max: 255)
    |> validate_length(:reason, max: 500)
    |> unique_constraint(:domain, name: :messaging_federation_peer_policies_domain_unique)
    |> foreign_key_constraint(:updated_by_id)
  end

  defp normalize_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/^https?:\/\//, "")
    |> String.split("/", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim(".")
  end

  defp normalize_domain(_), do: nil
end
