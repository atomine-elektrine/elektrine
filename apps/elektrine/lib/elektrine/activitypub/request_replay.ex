defmodule Elektrine.ActivityPub.RequestReplay do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "activitypub_request_replays" do
    field :nonce, :string
    field :key_id, :string
    field :actor_uri, :string
    field :http_method, :string
    field :request_path, :string
    field :query_string, :string
    field :signature_timestamp, :string
    field :digest, :string
    field :seen_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :nonce,
      :key_id,
      :actor_uri,
      :http_method,
      :request_path,
      :query_string,
      :signature_timestamp,
      :digest,
      :seen_at,
      :expires_at
    ])
    |> validate_required([
      :nonce,
      :key_id,
      :http_method,
      :request_path,
      :seen_at,
      :expires_at
    ])
    |> unique_constraint(:nonce, name: :activitypub_request_replays_nonce_unique)
  end
end
