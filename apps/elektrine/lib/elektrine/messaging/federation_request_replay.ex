defmodule Elektrine.Messaging.FederationRequestReplay do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_request_replays" do
    field :nonce, :string
    field :origin_domain, :string
    field :key_id, :string
    field :http_method, :string
    field :request_path, :string
    field :timestamp, :integer
    field :seen_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :nonce,
      :origin_domain,
      :key_id,
      :http_method,
      :request_path,
      :timestamp,
      :seen_at,
      :expires_at
    ])
    |> validate_required([
      :nonce,
      :origin_domain,
      :http_method,
      :request_path,
      :timestamp,
      :seen_at,
      :expires_at
    ])
    |> unique_constraint(:nonce, name: :messaging_federation_request_replays_nonce_unique)
  end
end
