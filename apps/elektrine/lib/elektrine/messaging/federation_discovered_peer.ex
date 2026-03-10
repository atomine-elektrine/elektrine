defmodule Elektrine.Messaging.FederationDiscoveredPeer do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_discovered_peers" do
    field :domain, :string
    field :base_url, :string
    field :discovery_url, :string
    field :protocol, :string
    field :protocol_id, :string
    field :protocol_version, :string
    field :trust_state, :string, default: "trusted"
    field :identity_fingerprint, :string
    field :previous_identity_fingerprint, :string
    field :last_key_change_at, :utc_datetime
    field :identity, :map, default: %{}
    field :endpoints, :map, default: %{}
    field :features, :map, default: %{}
    field :last_discovered_at, :utc_datetime
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(peer, attrs) do
    peer
    |> cast(attrs, [
      :domain,
      :base_url,
      :discovery_url,
      :protocol,
      :protocol_id,
      :protocol_version,
      :trust_state,
      :identity_fingerprint,
      :previous_identity_fingerprint,
      :last_key_change_at,
      :identity,
      :endpoints,
      :features,
      :last_discovered_at,
      :last_error
    ])
    |> update_change(:domain, &normalize_domain/1)
    |> validate_required([
      :domain,
      :base_url,
      :discovery_url,
      :trust_state,
      :identity_fingerprint,
      :identity,
      :last_discovered_at
    ])
    |> validate_format(:domain, ~r/^[a-z0-9.-]+$/, message: "must be a valid domain")
    |> validate_length(:domain, max: 255)
    |> validate_length(:base_url, max: 500)
    |> validate_length(:discovery_url, max: 500)
    |> validate_length(:protocol, max: 50)
    |> validate_length(:protocol_id, max: 50)
    |> validate_length(:protocol_version, max: 50)
    |> validate_inclusion(:trust_state, ["trusted", "rotated", "replaced"])
    |> validate_length(:identity_fingerprint, max: 128)
    |> validate_length(:previous_identity_fingerprint, max: 128)
    |> validate_length(:last_error, max: 1000)
    |> unique_constraint(:domain, name: :messaging_federation_discovered_peers_domain_unique)
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
